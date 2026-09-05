import OriveoProviderKit
import Testing

@testable import Oriveo

@Suite("Open AICompatible Stream State Tests")
struct OpenAICompatibleStreamStateTests {
    @Test("Deep Seek Shared Assembler Binding")
    func deepSeekSharedAssemblerBinding() throws {
        var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
        var state = OpenAICompatibleStreamState()

        let lines = [
            #"data: {"choices":[{"delta":{"reasoning_content":"Thought"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Answer"}}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":8,"prompt_cache_hit_tokens":60,"prompt_cache_miss_tokens":40,"completion_tokens_details":{"reasoning_tokens":5}}}"#,
            "data: [DONE]",
        ]
        var events: [StreamEvent] = []
        for line in lines {
            events.append(contentsOf: state.consume(try assembler.ingest(line)))
        }
        events.append(contentsOf: state.consume(try assembler.finish()))

        #expect(state.accumulatedText == "Answer")
        #expect(state.accumulatedReasoning == "Thought")
        #expect(events.count == 2)
        #expect(state.usageBreakdown == UsageBreakdown(
            promptTokens: 40,
            cachedInputTokens: 60,
            completionTokens: 8,
            reasoningTokens: 5,
            cacheReadObserved: true
        ))
    }

    @Test("Moonshot Shared Assembler Binding")
    func moonshotSharedAssemblerBinding() throws {
        var assembler = OpenAICompatibleStreamAssembler(profile: .moonshot)
        var state = OpenAICompatibleStreamState()
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"$web_search","arguments":"{\"query\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"test\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":80,"completion_tokens":5,"cached_tokens":48}}"#,
        ]
        for line in lines {
            _ = state.consume(try assembler.ingest(line))
        }
        _ = state.consume(try assembler.finish())

        #expect(state.toolCalls.count == 1)
        #expect(state.toolCalls.first?.providerCallID == "call-1")
        #expect(state.toolCalls.first?.rawArguments == #"{"query":"test"}"#)
        #expect(state.usageBreakdown.promptTokens == 32)
        #expect(state.usageBreakdown.cachedInputTokens == 48)
        #expect(state.usageBreakdown.cacheReadObserved)
    }

    @Test("Deep Seek Zero Is Different From Missing")
    func deepSeekZeroIsDifferentFromMissing() throws {
        var observedAssembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
        var observedState = OpenAICompatibleStreamState()
        _ = observedState.consume(try observedAssembler.ingest(
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10}}"#
        ))
        _ = observedState.consume(try observedAssembler.ingest("data: [DONE]"))
        _ = observedState.consume(try observedAssembler.finish())
        #expect(observedState.usageBreakdown.cachedInputTokens == 0)
        #expect(observedState.usageBreakdown.cacheReadObserved)

        var missingAssembler = OpenAICompatibleStreamAssembler(profile: .openAI)
        var missingState = OpenAICompatibleStreamState()
        _ = missingState.consume(try missingAssembler.ingest(
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        ))
        _ = missingState.consume(try missingAssembler.ingest("data: [DONE]"))
        _ = missingState.consume(try missingAssembler.finish())
        #expect(missingState.usageBreakdown.cachedInputTokens == 0)
        #expect(!missingState.usageBreakdown.cacheReadObserved)
    }

    @Test("Cache Write Stays Unobserved Because Wire Has No Field")
    func cacheWriteStaysUnobservedBecauseWireHasNoField() throws {
        var assembler = OpenAICompatibleStreamAssembler(profile: .openAI)
        var state = OpenAICompatibleStreamState()
        _ = state.consume(try assembler.ingest(
            #"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":40,"cache_write_tokens":20}}}"#
        ))
        _ = state.consume(try assembler.ingest("data: [DONE]"))
        _ = state.consume(try assembler.finish())

        let breakdown = state.usageBreakdown
        #expect(breakdown.cachedInputTokens == 40)
        #expect(breakdown.cacheReadObserved)
        #expect(!breakdown.cacheWriteObserved)
        #expect(breakdown.cacheCreation5mTokens == 0)
        #expect(breakdown.cacheCreation1hTokens == 0)
        #expect(breakdown.promptTokens == 60)
        #expect(breakdown.totalInputTokens == 100)
    }

    @Test("Multi Leg Usage Aggregation")
    func multiLegUsageAggregation() {
        var accumulator = ProviderTokenUsageAccumulator()
        accumulator.add(ProviderTokenUsage(inputTokens: 10, outputTokens: 2, cachedInputTokens: 4))
        accumulator.add(ProviderTokenUsage(inputTokens: 20, outputTokens: 3, cachedInputTokens: 5))

        #expect(accumulator.combined == ProviderTokenUsage(
            inputTokens: 30,
            outputTokens: 5,
            cachedInputTokens: 9
        ))
    }
}
