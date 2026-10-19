import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Every POST gets 200 plus the given SSE stream body; GET (model catalog etc.) returns an empty list.
private final class StreamFinishURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stream = ""

    static func session(stream: String) -> URLSession {
        lock.lock()
        self.stream = stream
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamFinishURLProtocol.self]
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

/// The stream of the OpenAI chat-compatible family carries a StreamFinish on `.done` (family openai_chat).
/// Clean criterion: a `[DONE]` or a non-empty finish_reason was seen; if neither was seen it is eof_without_marker.
/// Each case feeds raw SSE bytes to the three production services DeepSeek / Qwen / OpenRouter and asserts the done event they deliver.
@Suite("StreamFinish: OpenAI chat family (iOS)", .serialized)
struct StreamFinishOpenAIChatTests {
    private static let contentFrame = #"data: {"id":"c1","object":"chat.completion.chunk","model":"m","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#

    private static func finishFrame(_ reason: String) -> String {
        #"data: {"id":"c1","object":"chat.completion.chunk","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"\#(reason)"}]}"#
    }

    private static let usageFrame = #"data: {"id":"c1","object":"chat.completion.chunk","model":"m","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#

    private static func body(_ lines: [String]) -> String {
        lines.map { $0 + "\n\n" }.joined()
    }

    private static let key = "sk-stream-finish-test-0123456789"

    private static func message(kind: ProviderKind) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, text: "ping", providerKind: kind, providerName: kind.displayName, modelName: "m", state: .delivered)
    }

    private static func services(_ session: URLSession) -> [(ProviderKind, String, any ProviderServiceProtocol)] {
        [
            (.deepseek, "deepseek-chat", DeepSeekService(session: session)),
            (.qwen, "qwen-plus", QwenService(session: session)),
            (.openRouter, "openai/gpt-4o-mini", OpenRouterService(session: session)),
        ]
    }

    private static func drain(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> (text: String, result: ProviderChatResult?, finish: StreamFinish?, error: Error?) {
        var text = ""
        var result: ProviderChatResult?
        var finish: StreamFinish?
        do {
            for try await event in stream {
                if case let .delta(chunk) = event { text += chunk }
                if case let .done(value) = event { result = value }
                if case let .finish(value) = event { finish = value }
            }
        } catch {
            return (text, result, finish, error)
        }
        return (text, result, finish, nil)
    }

    @Test("openai_chat_done_with_length：finish_reason length + [DONE] → clean，finishRaw length")
    func openai_chat_done_with_length() async throws {
        await MetadataClient.shared.resetForTesting()
        let stream = Self.body([Self.contentFrame, Self.finishFrame("length"), Self.usageFrame, "data: [DONE]"])
        for (kind, modelID, service) in Self.services(StreamFinishURLProtocol.session(stream: stream)) {
            let drained = await Self.drain(service.sendMessageStream(
                apiKey: Self.key, modelID: modelID, messages: [Self.message(kind: kind)]
            ))
            #expect(drained.error == nil, "\(kind.rawValue)：\(String(describing: drained.error))")
            let result = try #require(drained.result, "\(kind.rawValue): no done")
            #expect(result.text == "Hello", "\(kind.rawValue)")
            #expect(
                result.finish == StreamFinish(family: .openaiChat, ended: .clean, finishRaw: "length"),
                "\(kind.rawValue)：\(String(describing: result.finish))"
            )
            #expect(
                result.finish.map {
                    StopReasonResolver.resolve(family: $0.family, ended: $0.ended, finishRaw: $0.finishRaw, hadContent: true)
                } == .length,
                "\(kind.rawValue)"
            )
        }
    }

    @Test("openai_chat_finish_without_done: finish_reason without [DONE] -> clean")
    func openai_chat_finish_without_done() async throws {
        await MetadataClient.shared.resetForTesting()
        let stream = Self.body([Self.contentFrame, Self.finishFrame("stop")])
        for (kind, modelID, service) in Self.services(StreamFinishURLProtocol.session(stream: stream)) {
            let drained = await Self.drain(service.sendMessageStream(
                apiKey: Self.key, modelID: modelID, messages: [Self.message(kind: kind)]
            ))
            #expect(drained.error == nil, "\(kind.rawValue)：\(String(describing: drained.error))")
            let result = try #require(drained.result, "\(kind.rawValue): no done")
            #expect(
                result.finish == StreamFinish(family: .openaiChat, ended: .clean, finishRaw: "stop"),
                "\(kind.rawValue)：\(String(describing: result.finish))"
            )
        }
    }

    @Test("openai_chat_eof_without_marker: neither finish_reason nor [DONE] -> eof_without_marker; DeepSeek still throws truncated")
    func openai_chat_eof_without_marker() async throws {
        await MetadataClient.shared.resetForTesting()
        let stream = Self.body([Self.contentFrame])
        for (kind, modelID, service) in Self.services(StreamFinishURLProtocol.session(stream: stream)) {
            let drained = await Self.drain(service.sendMessageStream(
                apiKey: Self.key, modelID: modelID, messages: [Self.message(kind: kind)]
            ))
            #expect(drained.text == "Hello", "\(kind.rawValue)")
            if kind == .deepseek {
                // DeepSeek still ends as a failure when the stream is cut; the error is recognizable as the EOF kind (used to record incomplete).
                #expect(drained.result == nil, "deepseek: a cut stream must not deliver done")
                #expect(drained.error as? ProviderStreamWireError == .truncated, "deepseek: \(String(describing: drained.error))")
                #expect(
                    drained.finish == StreamFinish(family: .openaiChat, ended: .eofWithoutMarker, finishRaw: nil),
                    "deepseek: eof-kind finish must be delivered before the throw, actual \(String(describing: drained.finish))"
                )
                continue
            }
            #expect(drained.error == nil, "\(kind.rawValue)：\(String(describing: drained.error))")
            let result = try #require(drained.result, "\(kind.rawValue): no done")
            #expect(
                result.finish == StreamFinish(family: .openaiChat, ended: .eofWithoutMarker, finishRaw: nil),
                "\(kind.rawValue)：\(String(describing: result.finish))"
            )
            #expect(
                result.finish.map {
                    StopReasonResolver.resolve(family: $0.family, ended: $0.ended, finishRaw: $0.finishRaw, hadContent: true)
                } == .incomplete,
                "\(kind.rawValue)"
            )
        }
    }

    // MARK: - llama.cpp native /completion

    /// Goes through production `OpenAIService.pumpLlamaCppNative` (the same function streamLlamaCppNative uses to read the stream).
    private static func runLlamaCpp(_ frames: [String]) async throws -> (text: String, finish: StreamFinish) {
        let lines = frames.flatMap { [$0, ""] }
        let source = AsyncStream<String> { input in
            lines.forEach { input.yield($0) }
            input.finish()
        }
        let (events, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        let result = try await OpenAIService.pumpLlamaCppNative(lines: source, apiKey: key, continuation: continuation)
        continuation.finish()
        var text = ""
        for try await event in events {
            if case let .delta(chunk) = event { text += chunk }
        }
        #expect(text == result.text)
        return result
    }

    private static let llamaContent = #"data: {"content":"Hello","stop":false}"#

    @Test("llama_cpp_stop_type_carries_finish: the last frame's stop_type becomes finishRaw; old servers' stopped_* are converted; a cut without stop:true = eof")
    func llama_cpp_stop_type_carries_finish() async throws {
        let cases: [(String, String, StopReason)] = [
            (#"data: {"content":"","stop":true,"stop_type":"eos","stopped_eos":true}"#, "eos", .stop),
            (#"data: {"content":"","stop":true,"stop_type":"limit","stopped_limit":true}"#, "limit", .length),
            // Servers older than stop_type (around b4000) only give a boolean.
            (#"data: {"content":"","stop":true,"stopped_eos":false,"stopped_word":true,"stopped_limit":false}"#, "word", .stop),
            (#"data: {"content":"","stop":true,"stopped_eos":false,"stopped_word":false,"stopped_limit":true}"#, "limit", .length),
            (#"data: {"content":"","stop":true,"stopped_eos":false,"stopped_word":false,"stopped_limit":false}"#, "none", .unknown),
        ]
        for (frame, raw, expected) in cases {
            let run = try await Self.runLlamaCpp([Self.llamaContent, frame])
            #expect(run.text == "Hello")
            #expect(run.finish == StreamFinish(family: .llamaCpp, ended: .clean, finishRaw: raw), "\(raw)：\(run.finish)")
            #expect(StopReasonResolver.resolve(family: run.finish.family, ended: run.finish.ended, finishRaw: run.finish.finishRaw, hadContent: true) == expected, "\(raw)")
        }
        let truncated = try await Self.runLlamaCpp([Self.llamaContent])
        #expect(truncated.finish == StreamFinish(family: .llamaCpp, ended: .eofWithoutMarker), "\(truncated.finish)")
        #expect(StopReasonResolver.resolve(family: truncated.finish.family, ended: truncated.finish.ended, finishRaw: truncated.finish.finishRaw, hadContent: true) == .incomplete)
    }
}
