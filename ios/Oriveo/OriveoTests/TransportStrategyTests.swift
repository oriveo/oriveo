import Foundation
import Testing
@testable import Oriveo

@Suite("Transport Registry Tests")
struct TransportRegistryTests {

    @Test("All Kinds Registered")
    func allKindsRegistered() {
        for kind in TransportKind.allCases {
            let strategy = TransportRegistry.strategy(for: kind)
            #expect(strategy.kind == kind)
        }
    }

    @Test("Unknown Kind Throws")
    func unknownKindThrows() {
        #expect(throws: UnsupportedTransportError.self) {
            _ = try TransportRegistry.getStrategy(for: "future_kind", modelID: "test")
        }
    }

    @Test("Empty Kind Throws")
    func emptyKindThrows() {
        #expect(throws: UnsupportedTransportError.self) {
            _ = try TransportRegistry.getStrategy(for: nil)
        }
        #expect(throws: UnsupportedTransportError.self) {
            _ = try TransportRegistry.getStrategy(for: "")
        }
        #expect(throws: UnsupportedTransportError.self) {
            _ = try TransportRegistry.getStrategy(for: "   ")
        }
    }

    @Test("Known Kind Strings")
    func knownKindStrings() throws {
        let chat = try TransportRegistry.getStrategy(for: "openai_chat")
        #expect(chat.kind == .openaiChat)

        let resp = try TransportRegistry.getStrategy(for: "openai_responses")
        #expect(resp.kind == .openaiResponses)

        let ant = try TransportRegistry.getStrategy(for: "anthropic_messages")
        #expect(ant.kind == .anthropicMessages)

        let gem = try TransportRegistry.getStrategy(for: "gemini_generate")
        #expect(gem.kind == .geminiGenerate)

        let dash = try TransportRegistry.getStrategy(for: "dashscope_native")
        #expect(dash.kind == .dashscopeNative)
    }

    @Test("Is Supported")
    func isSupported() {
        #expect(TransportRegistry.isSupported(kindRaw: "openai_chat") == true)
        #expect(TransportRegistry.isSupported(kindRaw: "future_kind") == false)
        #expect(TransportRegistry.isSupported(kindRaw: nil) == false)
        #expect(TransportRegistry.isSupported(kindRaw: "") == false)
    }
}

// MARK: - OpenAIChatStrategy parseStreamLine

@Suite("Open AIChat Strategy Tests")
struct OpenAIChatStrategyTests {

    @Test("Basic Delta")
    func basicDelta() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .delta(text) = events[0] {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected .delta event")
        }
        #expect(ctx.accumulatedText == "Hello")
    }

    @Test("Reasoning Delta")
    func reasoningDelta() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"data: {"choices":[{"delta":{"reasoning_content":"Thinking..."}}]}"#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .reasoning(text) = events[0] {
            #expect(text == "Thinking...")
        } else {
            Issue.record("Expected .reasoning event")
        }
    }

    @Test("Zhipu Web Search")
    func zhipuWebSearch() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"web_search":{"search_result":[{"link":"https://zhipu.com/x","title":"Zhipu","content":"Snippet"}]}}]}}]}
        """#
        let shape = MetadataClient.StreamShape(
            reasoningDeltaPath: nil,
            citationsBlockType: nil,
            citationsArrayPath: "choices.0.delta.tool_calls.0.web_search.search_result",
            citationUrlField: "link",
            citationTitleField: nil,
            citationSnippetField: nil,
            imageDataPath: nil
        )
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: shape)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://zhipu.com/x")
        #expect(cits[0].title == "Zhipu")
        #expect(cits[0].snippet == "Snippet")
    }

    @Test("Ignore Sentinels")
    func ignoreSentinels() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        #expect(strategy.parseStreamLine("data: [DONE]", ctx: &ctx, shape: nil).isEmpty)
        #expect(strategy.parseStreamLine("", ctx: &ctx, shape: nil).isEmpty)
        #expect(strategy.parseStreamLine("data: ", ctx: &ctx, shape: nil).isEmpty)
    }
}

// MARK: - AnthropicMessagesStrategy parseStreamLine

@Suite("Anthropic Messages Strategy Tests")
struct AnthropicMessagesStrategyTests {

    @Test("Text Delta")
    func textDelta() {
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        let line = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .delta(text) = events[0] {
            #expect(text == "Hi")
        } else {
            Issue.record("Expected .delta event")
        }
    }

    @Test("Thinking Delta")
    func thinkingDelta() {
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        let line = #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Pondering..."}}"#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .reasoning(text) = events[0] {
            #expect(text == "Pondering...")
        } else {
            Issue.record("Expected .reasoning event")
        }
    }

    @Test("Web Search Tool Result")
    func webSearchToolResult() {
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"type":"content_block_start","content_block":{"type":"web_search_tool_result","content":[{"url":"https://anth.com/a","title":"A","cited_text":"snippet"},{"url":"https://anth.com/b","title":"B"}]}}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 2)
        #expect(cits[0].url == "https://anth.com/a")
        #expect(cits[0].snippet == "snippet")
        #expect(cits[1].url == "https://anth.com/b")
    }
}

// MARK: - GeminiGenerateStrategy parseStreamLine

@Suite("Gemini Generate Strategy Tests")
struct GeminiGenerateStrategyTests {

    @Test("Text Part")
    func textPart() {
        let strategy = GeminiGenerateStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"candidates":[{"content":{"parts":[{"text":"Hello from Gemini"}]}}]}
        """#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .delta(text) = events[0] {
            #expect(text == "Hello from Gemini")
        } else {
            Issue.record("Expected .delta event")
        }
    }

    @Test("Reasoning Part")
    func reasoningPart() {
        let strategy = GeminiGenerateStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"candidates":[{"content":{"parts":[{"text":"thinking","thought":true}]}}]}
        """#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .reasoning(text) = events[0] {
            #expect(text == "thinking")
        } else {
            Issue.record("Expected .reasoning event")
        }
    }

    @Test("Grounding Chunks")
    func groundingChunks() {
        let strategy = GeminiGenerateStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"candidates":[{"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://gemini.com/a","title":"GemA"}},{"web":{"uri":"https://gemini.com/b","title":"GemB"}}]}}]}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 2)
        #expect(cits[0].url == "https://gemini.com/a")
        #expect(cits[0].title == "GemA")
    }
}

// MARK: - DashScopeNativeStrategy parseStreamLine

@Suite("Dash Scope Native Strategy Tests")
struct DashScopeNativeStrategyTests {

    @Test("Cumulative Text")
    func cumulativeText() {
        let strategy = DashScopeNativeStrategy()
        var ctx = StreamContext()

        let line1 = #"data: {"output":{"text":"Hello"}}"#
        let line2 = #"data: {"output":{"text":"Hello World"}}"#

        let events1 = strategy.parseStreamLine(line1, ctx: &ctx, shape: nil)
        if case let .delta(text) = events1[0] {
            #expect(text == "Hello")
        }

        let events2 = strategy.parseStreamLine(line2, ctx: &ctx, shape: nil)
        if case let .delta(text) = events2[0] {
            #expect(text == " World")
        }
        #expect(ctx.accumulatedText == "Hello World")
    }

    @Test("Search Info Citations")
    func searchInfoCitations() {
        let strategy = DashScopeNativeStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"output":{"text":"","search_info":{"search_results":[{"url":"https://dash.com/x","title":"Title","site_name":"Site","index":1}]}}}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://dash.com/x")
        #expect(cits[0].title == "Title")
        #expect(cits[0].index == 1)
    }
}

// MARK: - OpenAIResponsesStrategy

@Suite("Open AIResponses Strategy Tests")
struct OpenAIResponsesStrategyTests {

    @Test("Output Text Delta")
    func outputTextDelta() {
        let strategy = OpenAIResponsesStrategy()
        var ctx = StreamContext()
        let line = #"data: {"type":"response.output_text.delta","delta":"Hi"}"#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .delta(text) = events[0] {
            #expect(text == "Hi")
        }
    }

    @Test("Reasoning Delta")
    func reasoningDelta() {
        let strategy = OpenAIResponsesStrategy()
        var ctx = StreamContext()
        let line = #"data: {"type":"response.reasoning.delta","delta":"thinking"}"#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(events.count == 1)
        if case let .reasoning(text) = events[0] {
            #expect(text == "thinking")
        }
    }

    @Test("Url Citation Annotation")
    func urlCitationAnnotation() {
        let strategy = OpenAIResponsesStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://oai.com/a","title":"Oai","start_index":5,"end_index":15}}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://oai.com/a")
        #expect(cits[0].startIndex == 5)
        #expect(cits[0].endIndex == 15)
    }
}

// MARK: - AnthropicMessagesStrategy snippet shape override

@Suite("Anthropic Messages Strategy Snippet Shape Tests")
struct AnthropicMessagesStrategySnippetShapeTests {

    @Test("Inline Citation Snippet Shape")
    func inlineCitationSnippetShape() {
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"type":"content_block_delta","delta":{"type":"citations_delta","citation":{"url":"https://anth.io/a","title":"A","my_snippet":"customsnip"}}}
        """#
        let shape = MetadataClient.StreamShape(
            reasoningDeltaPath: nil,
            citationsBlockType: nil,
            citationsArrayPath: nil,
            citationUrlField: nil,
            citationTitleField: nil,
            citationSnippetField: "my_snippet",
            imageDataPath: nil
        )
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: shape)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].snippet == "customsnip")
    }

    @Test("Inline Citation Default Cited Text")
    func inlineCitationDefaultCitedText() {
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"type":"content_block_delta","delta":{"type":"citations_delta","citation":{"url":"https://anth.io/b","cited_text":"default snip"}}}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].snippet == "default snip")
    }
}

// MARK: - GeminiGenerateStrategy groundingSupports

@Suite("Gemini Grounding Supports Tests")
struct GeminiGroundingSupportsTests {

    @Test("Grounding Supports Backfills Range")
    func groundingSupportsBackfillsRange() {
        let strategy = GeminiGenerateStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"candidates":[{"groundingMetadata":{
          "groundingChunks":[
            {"web":{"uri":"https://g.com/a","title":"A"}},
            {"web":{"uri":"https://g.com/b","title":"B"}}
          ],
          "groundingSupports":[
            {"segment":{"startIndex":3,"endIndex":12},"groundingChunkIndices":[0]},
            {"segment":{"startIndex":50,"endIndex":80},"groundingChunkIndices":[1]}
          ]
        }}]}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 2)
        let a = cits.first(where: { $0.url == "https://g.com/a" })
        let b = cits.first(where: { $0.url == "https://g.com/b" })
        #expect(a?.startIndex == 3)
        #expect(a?.endIndex == 12)
        #expect(b?.startIndex == 50)
        #expect(b?.endIndex == 80)
    }
}


@Suite("Open Router Or Web Strategy Tests")
struct OpenRouterOrWebStrategyTests {

    /// citationsArrayPath = "choices.0.message.annotations"
    static let orWebShape = MetadataClient.StreamShape(
        reasoningDeltaPath: nil,
        citationsBlockType: nil,
        citationsArrayPath: "choices.0.message.annotations",
        citationUrlField: "url_citation.url",
        citationTitleField: "url_citation.title",
        citationSnippetField: nil,
        imageDataPath: nil
    )

    @Test("Or Web Annotations")
    func orWebAnnotations() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"choices":[{"message":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://or.com/a","title":"OR Article A"}},{"type":"url_citation","url_citation":{"url":"https://or.com/b","title":"OR Article B"}}]}}]}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: Self.orWebShape)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 2)
        #expect(cits[0].url == "https://or.com/a")
        #expect(cits[0].title == "OR Article A")
        #expect(cits[1].url == "https://or.com/b")
        #expect(cits[1].title == "OR Article B")
    }

    @Test("Or Web Flat Annotations")
    func orWebFlatAnnotations() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"choices":[{"message":{"annotations":[{"url":"https://or.com/flat","title":"Flat A"}]}}]}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: Self.orWebShape)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://or.com/flat")
        #expect(cits[0].title == "Flat A")
    }

    @Test("Or Plain Text No Citations")
    func orPlainTextNoCitations() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"data: {"choices":[{"delta":{"content":"hi"}}]}"#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: Self.orWebShape)
        #expect(ctx.citationsAccumulator.snapshot == nil)
        #expect(ctx.accumulatedText == "hi")
    }
}


@Suite("Moonshot Kimi Web Search Strategy Tests")
struct MoonshotKimiWebSearchStrategyTests {

    @Test("Kimi No Stream Shape")
    func kimiNoStreamShape() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"data: {"choices":[{"delta":{"content":"K2 says hi"}}]}"#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(ctx.citationsAccumulator.snapshot == nil)
        #expect(ctx.accumulatedText == "K2 says hi")
    }

    @Test("Kimi Forward Compat Annotations")
    func kimiForwardCompatAnnotations() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let hypotheticalShape = MetadataClient.StreamShape(
            reasoningDeltaPath: nil,
            citationsBlockType: nil,
            citationsArrayPath: "choices.0.delta.annotations",
            citationUrlField: "url_citation.url",
            citationTitleField: "url_citation.title",
            citationSnippetField: nil,
            imageDataPath: nil
        )
        let line = #"""
        data: {"choices":[{"delta":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://kimi.com/a","title":"Kimi A"}}]}}]}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: hypotheticalShape)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://kimi.com/a")
    }
}


@Suite("Relay Web Search Shape Resolution Tests")
struct RelayWebSearchShapeResolutionTests {

    @Test("Ant Web Tool Handles Web Search Tool Result")
    func antWebToolHandlesWebSearchToolResult() {
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"type":"content_block_start","content_block":{"type":"web_search_tool_result","content":[{"url":"https://relay-ant.com/x","title":"Relay Anthropic Result","cited_text":"snippet text"}]}}
        """#
        // citationsBlockType=web_search_tool_result, citationSnippetField=cited_text
        let antShape = MetadataClient.StreamShape(
            reasoningDeltaPath: nil,
            citationsBlockType: "web_search_tool_result",
            citationsArrayPath: nil,
            citationUrlField: nil,
            citationTitleField: nil,
            citationSnippetField: "cited_text",
            imageDataPath: nil
        )
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: antShape)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://relay-ant.com/x")
        #expect(cits[0].snippet == "snippet text")
    }

    @Test("Gem Web Handles Grounding Chunks")
    func gemWebHandlesGroundingChunks() {
        let strategy = GeminiGenerateStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"candidates":[{"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://relay-gem.com/x","title":"Relay Gemini Result"}}]}}]}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://relay-gem.com/x")
        #expect(cits[0].title == "Relay Gemini Result")
    }

    @Test("Oai Responses Web Handles Url Citation")
    func oaiResponsesWebHandlesUrlCitation() {
        let strategy = OpenAIResponsesStrategy()
        var ctx = StreamContext()
        let line = #"""
        data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://relay-oai.com/a","title":"Relay OpenAI Result","start_index":0,"end_index":10}}
        """#
        _ = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        let cits = ctx.citationsAccumulator.snapshot ?? []
        #expect(cits.count == 1)
        #expect(cits[0].url == "https://relay-oai.com/a")
        #expect(cits[0].startIndex == 0)
        #expect(cits[0].endIndex == 10)
    }
}
