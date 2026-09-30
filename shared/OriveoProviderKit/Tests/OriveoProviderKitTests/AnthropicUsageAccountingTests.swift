import Foundation
import OriveoProviderKit
import Testing

// Anthropic's input_tokens excludes cache reads and writes; `ProviderTokenUsage.inputTokens` is all
// input including cache hits. Counting only cache_creation made the whole usage nil as soon as the
// cache-read count exceeded input + creation, which is the normal case with prompt caching on.

@Suite("Anthropic usage accounting")
struct AnthropicUsageAccountingTests {
    private func usage(_ lines: [String]) throws -> ProviderTokenUsage? {
        var assembler = try ProviderTextStreamAssembler(transport: .anthropicMessages)
        for line in lines {
            _ = try assembler.ingest(line)
        }
        return try assembler.finish().compactMap { event -> ProviderTokenUsage? in
            if case .usage(let value) = event { return value }
            return nil
        }.last
    }

    @Test("cache reads and writes count toward total input, and message_delta does not count cache reads twice")
    func cacheReadCountsTowardTotalInput() throws {
        let result = try usage([
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000}}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        #expect(result == ProviderTokenUsage(inputTokens: 3212, outputTokens: 50, cachedInputTokens: 3000))
    }

    @Test("without cache fields the cached count stays nil rather than zero")
    func missingCacheFieldsStayNil() throws {
        let result = try usage([
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":9}}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        #expect(result == ProviderTokenUsage(inputTokens: 9, outputTokens: 1, cachedInputTokens: nil))
    }
}
