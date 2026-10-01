import Foundation
import OriveoProviderKit
import Testing

@testable import Oriveo

/// Locks the parsing of every "activity started" signal in the closed set.
///
/// Each case feeds **upstream frames in their real shape** through the production parsing path
/// and asserts that the production parser emits `.activity(.webSearch)`. The edges of the closed
/// set are locked as well: `tool_use`, `function_call`, other tool names and search-result events
/// must not be reported as an activity.
@MainActor
@Suite("Stream activity signals: parsing", .serialized)
struct StreamActivitySignalTests {

    private func activities(in events: [StreamEvent]) -> [StreamActivity] {
        events.compactMap { event in
            if case let .activity(activity) = event { return activity }
            return nil
        }
    }

    private func parse(_ kind: TransportKind, frames: [String]) -> [StreamEvent] {
        let strategy = TransportRegistry.strategy(for: kind)
        var ctx = StreamContext()
        return frames.flatMap { strategy.parseStreamLine($0, ctx: &ctx, shape: nil) }
    }

    // MARK: - Anthropic Messages

    @Test("Anthropic: content_block_start + server_tool_use + name=web_search starts an activity")
    func anthropicServerWebSearchStartEmitsActivity() {
        let events = parse(.anthropicMessages, frames: [
            #"{"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","usage":{"input_tokens":12,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me look that up."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01A","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"swift 6.2 release\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
        ])
        #expect(activities(in: events) == [.webSearch])
        // The signal comes after the preamble, which is still emitted as a body delta.
        #expect(events.contains { if case .delta("Let me look that up.") = $0 { return true } else { return false } })
    }

    @Test("Anthropic: a client tool_use, another server tool and a search-result block are not activities")
    func anthropicNonSearchBlocksDoNotEmitActivity() {
        let events = parse(.anthropicMessages, frames: [
            // A client tool_use, even one named web_search: a proposal nobody is executing, not
            // the server searching.
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01B","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"x\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            // A server tool outside the closed set.
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01C","name":"code_execution","input":{}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            // Search results: results coming back are not a start.
            #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_01A","content":[{"type":"web_search_result","url":"https://example.com/a","title":"A","encrypted_content":"abc","page_age":null}]}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":20}}"#,
        ])
        #expect(activities(in: events).isEmpty)
        // Confirms the frames really were parsed: the tool_use proposal still goes out as
        // .toolCallDeltas.
        #expect(events.contains { if case .toolCallDeltas = $0 { return true } else { return false } })
    }

    // MARK: - OpenAI Responses

    @Test("OpenAI Responses: output_item.added + item.type=web_search_call starts an activity")
    func responsesWebSearchCallAddedEmitsActivity() {
        let events = parse(.openaiResponses, frames: [
            #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_01","status":"in_progress"}}"#,
            #"{"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"ws_01","type":"web_search_call","status":"in_progress"}}"#,
            #"{"type":"response.web_search_call.in_progress","sequence_number":3,"output_index":0,"item_id":"ws_01"}"#,
            #"{"type":"response.web_search_call.searching","sequence_number":4,"output_index":0,"item_id":"ws_01"}"#,
        ])
        #expect(activities(in: events) == [.webSearch])
    }

    @Test("OpenAI Responses: a function_call item, another tool item and a finished search (output_item.done) are not activities")
    func responsesNonSearchItemsDoNotEmitActivity() {
        let events = parse(.openaiResponses, frames: [
            // A function_call, even one named web_search: a proposal, not a server-side search.
            #"{"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"fc_01","type":"function_call","status":"in_progress","call_id":"call_01","name":"web_search","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.done","sequence_number":3,"output_index":0,"item_id":"fc_01","arguments":"{\"query\":\"x\"}"}"#,
            // Built-in tools outside the closed set.
            #"{"type":"response.output_item.added","sequence_number":4,"output_index":1,"item":{"id":"fs_01","type":"file_search_call","status":"in_progress"}}"#,
            #"{"type":"response.output_item.added","sequence_number":5,"output_index":2,"item":{"id":"msg_01","type":"message","status":"in_progress","role":"assistant","content":[]}}"#,
            // The search has already finished: this cannot be the start signal.
            #"{"type":"response.output_item.done","sequence_number":6,"output_index":3,"item":{"id":"ws_01","type":"web_search_call","status":"completed","action":{"type":"search","query":"x"}}}"#,
            #"{"type":"response.web_search_call.completed","sequence_number":7,"output_index":3,"item_id":"ws_01"}"#,
            #"{"type":"response.completed","sequence_number":8,"response":{"id":"resp_01","status":"completed","output":[]}}"#,
        ])
        #expect(activities(in: events).isEmpty)
        #expect(events.contains { if case .toolCallDeltas = $0 { return true } else { return false } })
    }

    @Test("Recorded Responses web search: every web_search_call item yields one start signal")
    func recordedResponsesWebSearchYieldsOneSignalPerSearch() throws {
        let directory = ["shared", "test-fixtures", "provider-toolcall"]
        let payloads = try SSEFixtureFile.dataPayloads(
            of: SSEFixtureFile.locate(directory + ["grok_proxy.responses.web_search.sse"])
        )
        let manifest = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: SSEFixtureFile.locate(directory + ["expected.json"]))
        ) as? [String: Any])
        let entry = try #require((manifest["fixtures"] as? [[String: Any]])?.first {
            ($0["file"] as? String) == "grok_proxy.responses.web_search.sse"
        })
        let expectedSearches = try #require((entry["expected"] as? [String: Any])?["web_search_calls"] as? Int)

        let events = parse(.openaiResponses, frames: payloads)
        #expect(expectedSearches > 0)
        #expect(activities(in: events).count == expectedSearches)
        #expect(!events.contains { if case .toolCallDeltas = $0 { return true } else { return false } })
    }

    @Test("openai_chat and gemini have no start signal: tool_calls and grounding rely on the pause fallback")
    func protocolsOutsideTheClosedSetNeverEmitActivity() {
        let chat = parse(.openaiChat, frames: [
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"x\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])
        #expect(activities(in: chat).isEmpty)
        let gemini = parse(.geminiGenerate, frames: [
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"The answer"}]},"groundingMetadata":{"webSearchQueries":["x"],"groundingChunks":[{"web":{"uri":"https://example.com","title":"Example"}}]}}]}"#,
        ])
        #expect(activities(in: gemini).isEmpty)
    }

    // MARK: - Moonshot `$web_search` client loop

    @Test("Moonshot: an accepted tool call named $web_search starts an activity (production leg runner and loop)")
    func moonshotAcceptedBuiltinWebSearchEmitsActivity() async throws {
        ActivitySignalURLProtocol.reset([
            """
            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"kimi-k2","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"kimi-k2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_ws_1","type":"builtin_function","function":{"name":"$web_search","arguments":"{\\"search_result\\":{\\"search_id\\":\\"s1\\"}}"}}]}}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"kimi-k2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":20,"completion_tokens":8,"total_tokens":28}}

            data: [DONE]


            """,
            """
            data: {"id":"chatcmpl-2","object":"chat.completion.chunk","model":"kimi-k2","choices":[{"index":0,"delta":{"role":"assistant","content":"Found it."}}]}

            data: {"id":"chatcmpl-2","object":"chat.completion.chunk","model":"kimi-k2","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":40,"completion_tokens":4,"total_tokens":44}}

            data: [DONE]


            """,
        ])
        let produced = try await runMoonshotLoop(registry: ToolRegistry(entries: [
            MoonshotWebSearchTool(executeCall: { MoonshotWebSearchTool.builtinResultContent(for: $0) }),
        ]))
        #expect(produced.activities == [.webSearch])
        #expect(produced.text == "Found it.")
        #expect(ActivitySignalURLProtocol.requestCount == 2, "accepting $web_search must continue with a second leg")
    }

    @Test("Moonshot: a tool with no executor (web search off) or another tool name yields no activity")
    func moonshotUnhandledOrOtherToolsDoNotEmitActivity() async throws {
        let leg = """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"kimi-k2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_ws_1","type":"builtin_function","function":{"name":"$web_search","arguments":"{}"}}]}}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"kimi-k2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]


        """
        // Web search is off: the registry is empty, `$web_search` has no executor, the call is
        // not accepted, so nothing is being searched.
        ActivitySignalURLProtocol.reset([leg])
        let unhandled = try await runMoonshotLoop(registry: .empty)
        #expect(unhandled.activities.isEmpty)
        #expect(ActivitySignalURLProtocol.requestCount == 1)

        // The accepted call has another tool name (one registered dynamically by Formula, for
        // example): outside the closed set, so it must not be guessed to be a web search.
        let other = ToolLoopToolCall(
            id: "call_x", type: "function",
            function: .init(name: "web_search", arguments: "{}")
        )
        #expect(MoonshotWebSearchTool.streamActivity(forAcceptedCalls: [other]) == nil)
        #expect(MoonshotWebSearchTool.streamActivity(forAcceptedCalls: []) == nil)
    }

    private struct MoonshotLoopOutput {
        var activities: [StreamActivity]
        var text: String
    }

    /// Production parts: `MoonshotToolLoopLegRunner` (the ProviderKit assembler decodes the
    /// stream) and the `ToolCallLoop` allow-list decision. Progress events are translated by
    /// `MoonshotWebSearchTool.streamActivity(forAcceptedCalls:)`, the same function the
    /// `onProgress` handler in `MoonshotService.sendMessageStream` calls.
    private func runMoonshotLoop(registry: ToolRegistry) async throws -> MoonshotLoopOutput {
        var request = URLRequest(url: URL(string: "https://activity-signal.test/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "kimi-k2",
            "stream": true,
            "messages": [["role": "user", "content": "What is in the news today?"]],
            "tools": [["type": "builtin_function", "function": ["name": "$web_search"]]],
        ])
        let session = ActivitySignalURLProtocol.session()
        let runner = MoonshotToolLoopLegRunner(
            initialRequest: request,
            kimiShape: nil,
            perform: { try await session.bytes(for: $0) },
            citationsSink: { _ in }
        )
        let loop = ToolCallLoop(
            registry: registry,
            legRunner: runner,
            adapter: OpenAIChatToolAdapter(includesToolNameInResult: true),
            limits: ToolCallLoop.Limits(maxSteps: 3),
            includesReasoningInAssistantMessage: true
        )
        let collector = ActivityCollector()
        let result = try await loop.run(messages: []) { event in
            if case let .toolCallsAccepted(calls) = event,
               let activity = MoonshotWebSearchTool.streamActivity(forAcceptedCalls: calls) {
                await collector.append(activity)
            }
        }
        return MoonshotLoopOutput(activities: await collector.activities, text: result.text)
    }
}

/// The input of Anthropic's built-in web search arrives as `input_json_delta` on a
/// `server_tool_use` block. A parser that treats it as a tool-call delta without checking that
/// the block at that index is a `tool_use` ends the stream with an extra tool call that has no id
/// and no name, which then shows up as a wrong "unhandled tool call" card.
/// `AnthropicToolCallStreamDecoder` only accumulates block indexes that were opened by a
/// `tool_use` `content_block_start`; these tests lock that invariant with real frames.
@MainActor
@Suite("Anthropic server_tool_use input is not a tool call")
struct AnthropicServerToolInputRegressionTests {

    /// Frames recorded from a real Anthropic web-search stream, with the encrypted result payload
    /// shortened.
    private static let recordedWebSearchFrames: [String] = [
        #"{"type":"message_start","message":{"model":"claude-sonnet-5","id":"msg_011CfZ030BktWN79OzI3PpBA","type":"message","role":"assistant","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":432,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"","citations":[]}             }"#,
        #"{"type": "ping"}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I'll lo"}   }"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok that up now."}             }"#,
        #"{"type":"content_block_stop","index":0               }"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01bug3W20DWB0LwoUvGoH0nW","name":"web_search","input":{}}         }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{"}      }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\""} }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"query"}   }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\""}         }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":": "}               }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"latest"}  }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" stable"}  }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" release"}         }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" of"}             }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Go"}           }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" programming"}       }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" language"}            }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\""}               }"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"}"}             }"#,
        #"{"type":"content_block_stop","index":1              }"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_01bug3W20DWB0LwoUvGoH0nW","content":[{"type":"web_search_result","title":"Release History","url":"https://tip.golang.org/doc/devel/release","encrypted_content":"LXR2sEKG15D7t+iACQOGvBPk8o4rE/mInqz0l2fUYuqnDuOJOCDfn4KX","page_age":null}]}          }"#,
        #"{"type":"content_block_stop","index":2          }"#,
        #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":"","citations":[]}             }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"The la"}             }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"test s"}     }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"ta"}             }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"bl"}      }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"e release "}    }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"of "}             }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"G"}          }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"o"}  }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":" "}              }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"is Go"}           }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":" 1"}          }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"."}        }"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"27."}}"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"1"}              }"#,
        #"{"type":"content_block_stop","index":3               }"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":432,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":93,"server_tool_use":{"web_search_requests":1,"web_fetch_requests":0}}         }"#,
        #"{"type":"message_stop"         }"#,
    ]

    @Test("Recorded web search: server_tool_use + input_json_delta produces no toolCallDeltas and exactly one search start signal")
    func recordedWebSearchStreamProducesNoToolCalls() throws {
        let payloads = Self.recordedWebSearchFrames
        // Sanity check on the frames: they do contain the server_tool_use start and the
        // input_json_delta fragments attached to it (index 1).
        #expect(payloads.contains { $0.contains(#""type":"server_tool_use""#) && $0.contains(#""index":1"#) })
        let serverToolInputFrames = payloads.filter {
            $0.contains(#""type":"input_json_delta""#) && $0.contains(#""index":1"#)
        }
        #expect(serverToolInputFrames.count >= 8)

        let strategy = TransportRegistry.strategy(for: .anthropicMessages)
        var ctx = StreamContext()
        var events: [StreamEvent] = []
        for payload in payloads {
            events += strategy.parseStreamLine(payload, ctx: &ctx, shape: nil)
        }
        // The trailing flush, which the service always runs once the stream ends, must not
        // surface a phantom proposal either.
        events += AnthropicMessagesStrategy.flushToolCalls(ctx: &ctx)

        let toolCalls = events.flatMap { event -> [ProviderToolCall] in
            if case let .toolCallDeltas(calls) = event { return calls }
            return []
        }
        #expect(toolCalls.isEmpty, "server_tool_use input was treated as a tool call: \(toolCalls)")
        let activities = events.filter { if case .activity(.webSearch) = $0 { return true } else { return false } }
        #expect(activities.count == 1)
        #expect(ctx.accumulatedText.hasPrefix("I'll look that up now."))
        #expect(!ctx.citationsAccumulator.citations.isEmpty, "web_search_tool_result still feeds the citations")
    }

    @Test("The decoder only accumulates blocks opened by tool_use: server_tool_use input is ignored and a real tool_use in the same stream is assembled")
    func decoderAccumulatesOnlyBlocksOpenedByToolUse() throws {
        func frame(_ json: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        var decoder = AnthropicToolAdapter().makeStreamDecoder()
        var calls: [ProviderToolCall] = []
        for json in [
            // Real frames from the recording: the server_tool_use at index 1 and its input fragments.
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01bug3W20DWB0LwoUvGoH0nW","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"query\": \"latest stable\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            // A real client tool_use in the same turn.
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01W","name":"get_weather","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"Melbourne\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":40}}"#,
        ] {
            calls += decoder.ingest(frame: try frame(json))
        }
        calls += decoder.finish()

        #expect(calls.count == 1, "only get_weather is expected; anything more is server_tool_use input turned into a phantom proposal")
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.providerCallID == "toolu_01W")
        #expect(calls.first?.rawArguments == #"{"city":"Melbourne"}"#)
    }

    @Test("Shared corpus: a real tool_use stream still yields toolCallDeltas and no activity")
    func sharedToolUseFixtureStillYieldsToolCalls() throws {
        let payloads = try SSEFixtureFile.dataPayloads(of: SSEFixtureFile.locate([
            "shared", "test-fixtures", "provider-toolcall", "anthropic.tool_use.sse",
        ]))
        let strategy = TransportRegistry.strategy(for: .anthropicMessages)
        var ctx = StreamContext()
        var events: [StreamEvent] = []
        for payload in payloads {
            events += strategy.parseStreamLine(payload, ctx: &ctx, shape: nil)
        }
        events += AnthropicMessagesStrategy.flushToolCalls(ctx: &ctx)

        let toolCalls = events.flatMap { event -> [ProviderToolCall] in
            if case let .toolCallDeltas(calls) = event { return calls }
            return []
        }
        #expect(!toolCalls.isEmpty)
        #expect(toolCalls.allSatisfy { !$0.name.isEmpty })
        #expect(!events.contains { if case .activity = $0 { return true } else { return false } })
    }
}

private enum SSEFixtureFile {
    /// Walks up from this file until the given path exists.
    static func locate(_ components: [String]) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = components.reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// SSE text to the payload of every `data:` line, stripping the `data: ` prefix line by line
    /// the same way the services do.
    static func dataPayloads(of url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("data: ") }
            .map { String($0.dropFirst(6)) }
    }
}

private actor ActivityCollector {
    private(set) var activities: [StreamActivity] = []
    func append(_ activity: StreamActivity) { activities.append(activity) }
}

/// A mock that replays scripted SSE bodies, one per request (Moonshot runs several legs).
private final class ActivitySignalURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var script: [Data] = []
    nonisolated(unsafe) private static var served = 0
    private static let lock = NSLock()

    static func reset(_ bodies: [String]) {
        lock.withLock {
            script = bodies.map { Data($0.utf8) }
            served = 0
        }
    }

    static var requestCount: Int { lock.withLock { served } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ActivitySignalURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: Data? = Self.lock.withLock {
            guard Self.served < Self.script.count else { return nil }
            defer { Self.served += 1 }
            return Self.script[Self.served]
        }
        guard let body, let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
