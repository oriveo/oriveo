import Foundation
import Testing

@testable import OriveoProviderKit

@Suite("Provider URL session origin checks")
struct ProviderURLSessionFactoryTests {
    @Test("origin compares scheme, host and effective port")
    func sameOriginSemantics() {
        let source = URL(string: "https://api.deepseek.com/v1/chat")!
        #expect(ProviderURLSessionFactory.isSameOrigin(
            source, URL(string: "https://api.deepseek.com:443/other")!
        ))
        #expect(!ProviderURLSessionFactory.isSameOrigin(
            source, URL(string: "https://api.moonshot.ai/v1/chat")!
        ))
        #expect(!ProviderURLSessionFactory.isSameOrigin(
            source, URL(string: "http://api.deepseek.com/v1/chat")!
        ))
        #expect(!ProviderURLSessionFactory.isSameOrigin(
            source, URL(string: "https://api.deepseek.com:8443/v1/chat")!
        ))
    }
}

// These tests pin the parts of the OpenAI-compatible stream that providers disagree about:
// where cached tokens live, how reasoning is delivered, and how fragmented tool calls are
// reassembled. They run against the assembler itself so that a provider quirk is covered once,
// independently of any client that embeds it.

private func drain(
    _ lines: [String],
    profile: ProviderWireProfile
) -> [ProviderStreamEvent] {
    var assembler = OpenAICompatibleStreamAssembler(profile: profile)
    var events: [ProviderStreamEvent] = []
    for line in lines {
        events.append(contentsOf: try! assembler.ingest(line))
        if assembler.isDone { break }
    }
    // Terminal evidence is asserted separately; these cases feed partial streams on purpose.
    events.append(contentsOf: try! assembler.finish(requireTerminalEvidence: false))
    return events
}

private func text(_ events: [ProviderStreamEvent]) -> String {
    events.reduce(into: "") { acc, event in
        if case .textDelta(let value) = event { acc += value }
    }
}

private func reasoning(_ events: [ProviderStreamEvent]) -> String {
    events.reduce(into: "") { acc, event in
        if case .reasoningDelta(let value) = event { acc += value }
    }
}

private func usage(_ events: [ProviderStreamEvent]) -> ProviderTokenUsage? {
    events.compactMap { event -> ProviderTokenUsage? in
        if case .usage(let value) = event { return value }
        return nil
    }.first
}

private func toolCalls(_ events: [ProviderStreamEvent]) -> [ProviderToolCall] {
    events.compactMap { event in
        if case .toolCall(let call) = event { return call }
        return nil
    }
}

@Suite("OpenAI-compatible stream assembler")
struct OpenAICompatibleStreamAssemblerTests {
    @Test("an error object inside a 2xx stream throws")
    func inBandErrorThrows() {
        var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
        #expect(throws: ProviderStreamWireError.upstreamError) {
            _ = try assembler.ingest(#"data: {"error":{"message":"quota"}}"#)
        }
    }

    @Test("a stream ending without DONE or a finish reason is truncated, not finished")
    func abruptEOFThrows() throws {
        var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
        _ = try assembler.ingest(#"data: {"choices":[{"delta":{"content":"partial"}}]}"#)
        #expect(throws: ProviderStreamWireError.truncated) {
            _ = try assembler.finish()
        }
    }

    @Test("an incomplete or negative usage object yields no usage event")
    func invalidUsageIsAbsent() {
        let missing = drain([
            #"data: {"choices":[],"usage":{"prompt_tokens":12}}"#,
            "data: [DONE]",
        ], profile: .moonshot)
        let negative = drain([
            #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":-1}}"#,
            "data: [DONE]",
        ], profile: .moonshot)
        #expect(usage(missing) == nil)
        #expect(usage(negative) == nil)
    }

    @Test("non-data lines are ignored and nothing after [DONE] is read")
    func ignoresNoiseAndStopsAtDone() {
        let events = drain([
            ": keep-alive",
            "event: message",
            #"data: {"choices":[{"delta":{"content":"A"}}]}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":"B"}}]}"#,
        ], profile: .deepSeek)

        #expect(text(events) == "A")
    }

    @Test("a malformed chunk is skipped without breaking the stream")
    func malformedChunkDoesNotBreakStream() {
        let events = drain([
            #"data: {"choices":[{"delta":{"content":"before"}}]}"#,
            "data: {not-json",
            #"data: {"choices":[{"delta":{"content":"after"}},{"delta":{"content":"ignore-second"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ], profile: .deepSeek)

        #expect(text(events) == "beforeafter")
        guard case .finished(let reason) = events.last else {
            Issue.record("last event must be finished, got \(String(describing: events.last))")
            return
        }
        #expect(reason == "stop")
    }

    @Test("a chunk whose content is an array still yields its usage, tool call and finish reason")
    func arrayContentDoesNotDiscardTheRestOfTheChunk() throws {
        // Mistral delivers reasoning as typed content blocks under the same `content` key that
        // every other provider uses for a plain string. The blocks are read by the recipe parser,
        // but `usage`, `tool_calls` and `finish_reason` ride along on that same chunk and are the
        // assembler's job, so a non-string `content` must not cost the whole frame.
        var assembler = OpenAICompatibleStreamAssembler(
            profile: .mistral,
            responseParserKinds: ["mistral_reasoning_v1"]
        )
        var events = try assembler.ingest(
            #"data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"text":"weighing it up"}]},{"type":"text","text":"the answer"}],"tool_calls":[{"index":0,"id":"call_mistral","function":{"name":"get_weather","arguments":"{\"city\":\"Melbourne\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":11,"completion_tokens":4}}"#
        )
        events.append(contentsOf: try assembler.finish(requireTerminalEvidence: false))

        #expect(reasoning(events) == "weighing it up")
        #expect(text(events) == "the answer")
        #expect(toolCalls(events).map(\.name) == ["get_weather"])
        #expect(toolCalls(events).first?.rawArguments == #"{"city":"Melbourne"}"#)
        #expect(usage(events) == ProviderTokenUsage(inputTokens: 11, outputTokens: 4, cachedInputTokens: nil))
        guard case .finished(let reason) = events.last else {
            Issue.record("last event must be finished, got \(String(describing: events.last))")
            return
        }
        #expect(reason == "tool_calls")
    }

    @Test("tool call fragments are assembled by index and emitted in index order")
    func toolCallsAssembleByIndex() {
        let events = drain([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"fs__write","arguments":"{\"path\""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"fs__read","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":":\"/tmp/a\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ], profile: .deepSeek)

        let calls = toolCalls(events)
        #expect(calls.count == 2)
        // Index order, which dictionary iteration would not guarantee.
        #expect(calls.map(\.name) == ["fs.read", "fs.write"])
        #expect(calls[0].providerCallID == "call_a")
        #expect(calls[1].rawArguments == #"{"path":"/tmp/a"}"#)
    }

    @Test("a fragment without an index continues the call most recently addressed")
    func missingIndexReusesPrevious() {
        let events = drain([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"fs__read","arguments":"{\"p\""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":":1}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ], profile: .deepSeek)

        let calls = toolCalls(events)
        #expect(calls.count == 1)
        #expect(calls[0].rawArguments == #"{"p":1}"#)
    }

    @Test("tool call fragments arriving after the finish reason are ignored")
    func lateToolCallDeltasAreDropped() {
        let events = drain([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"fs__read","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"evil\":1}"}}]}}]}"#,
        ], profile: .deepSeek)

        let calls = toolCalls(events)
        #expect(calls.count == 1)
        #expect(calls[0].rawArguments == "{}")
    }

    // MARK: - Usage: where each provider reports cached tokens

    @Test("DeepSeek reports cached tokens as a hit/miss split that sums to prompt_tokens")
    func deepSeekCachedTokens() {
        let full = drain([
            #"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":7,"prompt_cache_hit_tokens":64,"prompt_cache_miss_tokens":36}}"#,
        ], profile: .deepSeek)
        #expect(usage(full) == ProviderTokenUsage(inputTokens: 100, outputTokens: 7, cachedInputTokens: 64))

        let missingPrompt = drain([
            #"data: {"choices":[],"usage":{"completion_tokens":7,"prompt_cache_hit_tokens":64,"prompt_cache_miss_tokens":36}}"#,
        ], profile: .deepSeek)
        // DeepSeek guarantees hit + miss == prompt_tokens, so the input total is recoverable.
        #expect(usage(missingPrompt)?.inputTokens == 100)
    }

    @Test("a reported zero cached tokens stays zero and is not turned into nil")
    func cachedZeroIsDifferentFromMissing() {
        let observed = drain([
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10}}"#,
        ], profile: .deepSeek)
        #expect(usage(observed)?.cachedInputTokens == 0)

        let missing = drain([
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#,
        ], profile: .deepSeek)
        #expect(usage(missing)?.cachedInputTokens == nil)
    }

    @Test("Moonshot reports cached tokens at the top level of usage")
    func moonshotTopLevelCachedTokens() {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":80,"completion_tokens":5,"cached_tokens":48}}"#
        #expect(usage(drain([line], profile: .moonshot))?.cachedInputTokens == 48)
        // Read with OpenAI's profile the same payload reports nothing, because that profile
        // looks in the details object Moonshot never fills in.
        #expect(usage(drain([line], profile: .openAI))?.cachedInputTokens == nil)
    }

    @Test("OpenAI reports cached tokens inside prompt_tokens_details")
    func openAIPromptTokensDetails() {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":80,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":32}}}"#
        #expect(usage(drain([line], profile: .openAI))?.cachedInputTokens == 32)
        #expect(usage(drain([line], profile: .moonshot))?.cachedInputTokens == nil)
    }

    @Test("reasoning tokens are accepted as a subset of the output tokens")
    func reasoningUsageSubset() {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8,"completion_tokens_details":{"reasoning_tokens":5}}}"#
        #expect(usage(drain([line], profile: .deepSeek)) == ProviderTokenUsage(
            inputTokens: 12,
            outputTokens: 8,
            cachedInputTokens: nil,
            reasoningOutputTokens: 5
        ))
    }

    @Test("a relay profile leaves cached tokens nil rather than reporting zero")
    func unknownProfileLeavesCachedNil() {
        let profile = ProviderWireProfile.relay(baseURL: URL(string: "https://relay.invalid/v1")!)
        let events = drain([
            #"data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":3,"cached_tokens":5}}"#,
        ], profile: profile)
        #expect(usage(events)?.cachedInputTokens == nil)
        #expect(usage(events)?.inputTokens == 9)
    }

    @Test("usage is replaced, not accumulated, and reported once")
    func usageIsReplacedNotAccumulated() {
        let events = drain([
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":1}}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":9}}"#,
        ], profile: .deepSeek)
        #expect(usage(events) == ProviderTokenUsage(inputTokens: 10, outputTokens: 9, cachedInputTokens: nil))
        #expect(events.filter { if case .usage = $0 { return true } else { return false } }.count == 1)
    }

    // MARK: - Reasoning delivery

    @Test("reasoning_content is reported as reasoning and kept out of the answer")
    func reasoningContentField() {
        let events = drain([
            #"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"answer"}}]}"#,
        ], profile: .deepSeek)

        #expect(reasoning(events) == "thinking")
        #expect(text(events) == "answer")
    }

    @Test("a profile that delivers no reasoning ignores a reasoning_content field")
    func reasoningIgnoredWhenProfileSaysNone() {
        let events = drain([
            #"data: {"choices":[{"delta":{"reasoning_content":"should-not-appear"}}]}"#,
        ], profile: .groq)
        #expect(reasoning(events).isEmpty)
    }

    @Test("a think tag split across deltas is still recognised")
    func inlineThinkTagsSplitAcrossDeltas() {
        let events = drain([
            #"data: {"choices":[{"delta":{"content":"<thi"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"nk>reasoning"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"</think>body"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ], profile: .miniMax)

        #expect(reasoning(events) == "reasoning")
        #expect(text(events) == "body")
    }

    @Test("a trailing partial tag is flushed as answer text")
    func inlineThinkTagsTailIsFlushed() {
        let events = drain([
            #"data: {"choices":[{"delta":{"content":"body<th"}}]}"#,
        ], profile: .miniMax)
        #expect(text(events) == "body<th")
    }

    @Test("finished is emitted exactly once, as the last event")
    func finishedIsAlwaysLast() {
        let events = drain([
            #"data: {"choices":[{"delta":{"content":"x"}}]}"#,
            "data: [DONE]",
        ], profile: .deepSeek)

        let finishedCount = events.filter { if case .finished = $0 { return true } else { return false } }.count
        #expect(finishedCount == 1)
        guard case .finished = events.last else {
            Issue.record("last event must be finished")
            return
        }
    }
}

@Suite("SSE line splitter")
struct SSELineSplitterTests {
    @Test("a line split across chunks is emitted once it completes")
    func linesSpanningChunks() {
        var splitter = SSELineSplitter()
        #expect(splitter.feed(Data("data: {\"a\"".utf8)).isEmpty)
        #expect(splitter.feed(Data(":1}\ndata: x\n".utf8)) == [#"data: {"a":1}"#, "data: x"])
    }

    @Test("CRLF and LF streams split identically")
    func crlfAndLf() {
        var splitter = SSELineSplitter()
        #expect(splitter.feed(Data("a\r\nb\n".utf8)) == ["a", "b"])
    }

    @Test("flush returns a trailing line without a newline, once")
    func flushTail() {
        var splitter = SSELineSplitter()
        _ = splitter.feed(Data("a\nb".utf8))
        #expect(splitter.flush() == "b")
        #expect(splitter.flush() == nil)
    }
}
