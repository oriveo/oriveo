import Foundation

/// Splits a byte stream into SSE lines.
///
/// Chunk boundaries fall wherever the network puts them, so a line can arrive in pieces and a
/// single chunk can contain several. Bytes are buffered until a newline is seen; a `\r` before
/// it is dropped, so CRLF and LF streams are handled identically.
public struct SSELineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Self.line(from: buffer[buffer.startIndex ..< newline]))
            buffer.removeSubrange(buffer.startIndex ... newline)
        }
        return lines
    }

    /// Returns whatever is left in the buffer when the stream ends without a final newline.
    public mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = Self.line(from: buffer[buffer.startIndex ..< buffer.endIndex])
        buffer.removeAll()
        return line
    }

    private static func line(from raw: Data) -> String {
        var slice = raw
        if slice.last == 0x0D { slice = slice.dropLast() }
        return String(decoding: slice, as: UTF8.self)
    }
}

/// Turns an OpenAI-compatible SSE stream into `ProviderStreamEvent`s, including fragmented
/// `tool_calls` and usage.
///
/// The rules that matter:
/// 1. only `data:` lines are read; comments, other SSE fields and the `[DONE]` sentinel are
///    recognised and produce nothing;
/// 2. a chunk that does not decode is skipped rather than fatal - relays inject occasional
///    malformed frames, and one bad chunk must not cost the whole answer;
/// 3. `tool_calls` arrive as fragments keyed by index and are assembled in index order, so the
///    caller sees each call once and complete;
/// 4. reasoning is normalised regardless of how it was delivered, with `<think>` tags parsed by
///    `ThinkingTagParser` so a tag split across two deltas still resolves and never leaks into
///    the answer text.
public struct OpenAICompatibleStreamAssembler {
    /// True once `[DONE]` has been seen; further lines are ignored from that point on.
    public private(set) var isDone = false

    private let profile: ProviderWireProfile
    private let responseParserKinds: Set<String>
    private var toolCalls = OpenAICompatibleToolCallAccumulator()
    private var usage: ProviderTokenUsage?
    private var finishReason: String?
    private var thinkingParser = ThinkingTagParser()
    private var reasoningDetails: [Int: [String: ProviderRecipeValue]] = [:]
    private var reasoningDetailsInvalid = false
    private var nextReasoningDetailIndex = 0

    public init(profile: ProviderWireProfile, responseParserKind: String? = nil) {
        self.profile = profile
        self.responseParserKinds = Set(responseParserKind.map { [$0] } ?? [])
    }

    public init(profile: ProviderWireProfile, responseParserKinds: Set<String>) {
        self.profile = profile
        self.responseParserKinds = responseParserKinds
    }

    public mutating func ingest(_ line: String) throws -> [ProviderStreamEvent] {
        guard !isDone, !line.isEmpty else { return [] }
        // Lines starting with `:` are SSE comments, used for keep-alives.
        guard !line.hasPrefix(":"), line.hasPrefix("data:") else { return [] }

        var payload = line.dropFirst("data:".count)
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }
        if payload == "[DONE]" {
            isDone = true
            return []
        }
        guard let data = payload.data(using: .utf8) else { return [] }
        let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let rawObject, rawObject["error"] != nil {
            throw ProviderStreamWireError.upstreamError
        }
        var events = rawObject.map { parserSpecificEvents(from: $0) } ?? []
        guard let chunk = try? Self.chunkDecoder.decode(OpenAICompatibleChunk.self, from: data) else { return events }

        // Usage replaces rather than accumulates: providers resend a running total.
        if let raw = chunk.usage { usage = Self.usage(from: raw, profile: profile) }

        // Only the first choice is read: requests are always single-completion, and the final
        // usage chunk legitimately carries an empty `choices` array.
        let choice = chunk.choices?.first
        if let content = choice?.delta?.content, !content.isEmpty {
            events.append(contentsOf: textEvents(for: content))
        }
        // Empty reasoning deltas are forwarded on purpose. DeepSeek opens a long reasoning turn
        // with `reasoning_content: ""`, and dropping those frames leaves the caller with no
        // signal at all for minutes while the model thinks. An absent field decodes to nil and
        // is skipped; an empty string is a real observation that the turn has started.
        if profile.reasoningDelivery == .reasoningContentField,
           let reasoning = choice?.delta?.reasoningContent {
            events.append(.reasoningDelta(reasoning))
        }
        if let deltas = choice?.delta?.toolCalls {
            toolCalls.accumulate(deltas)
        }
        if let reason = choice?.finishReason, !reason.isEmpty {
            finishReason = reason
            events.append(contentsOf: flushThinkingTail())
            events.append(contentsOf: flushOpaqueContinuation())
            events.append(contentsOf: flushProposals())
        }
        return events
    }

    /// Flushes everything held back mid-stream and closes the stream: pending thinking text,
    /// continuation state, buffered tool calls, then usage if any, and `finished` last. Callers
    /// can rely on `finished` being the final event.
    ///
    /// With `requireTerminalEvidence`, a stream that never delivered `[DONE]` or a finish reason
    /// is reported as truncated instead of passed off as a complete answer.
    public mutating func finish(
        requireTerminalEvidence: Bool = true
    ) throws -> [ProviderStreamEvent] {
        if requireTerminalEvidence, !isDone, finishReason == nil {
            throw ProviderStreamWireError.truncated
        }
        var events = flushThinkingTail()
        events.append(contentsOf: flushOpaqueContinuation())
        events.append(contentsOf: flushProposals())
        if let usage { events.append(.usage(usage)) }
        events.append(.finished(reason: finishReason))
        return events
    }

    // MARK: - Inline thinking tags

    /// Routes answer text through the thinking-tag parser when the provider inlines reasoning.
    /// The parser holds back any partial tag, so a `<think>` split across two deltas is still
    /// recognised.
    private mutating func textEvents(for content: String) -> [ProviderStreamEvent] {
        guard profile.reasoningDelivery == .inlineThinkTags else {
            return [.textDelta(content)]
        }
        return thinkingParser.parse(content).map(Self.event(from:))
    }

    /// Releases whatever the parser was holding back at end of stream. A trailing fragment such
    /// as `<thi` was never a tag, so it belongs to the answer and is emitted as text.
    private mutating func flushThinkingTail() -> [ProviderStreamEvent] {
        guard profile.reasoningDelivery == .inlineThinkTags else { return [] }
        return thinkingParser.parse("", final: true).map(Self.event(from:))
    }

    private static func event(from segment: ThinkingTagParser.Segment) -> ProviderStreamEvent {
        switch segment {
        case .text(let value): return .textDelta(value)
        case .reasoning(let value): return .reasoningDelta(value)
        }
    }

    // MARK: - recipe parser-specific reasoning

    private mutating func parserSpecificEvents(from object: [String: Any]) -> [ProviderStreamEvent] {
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        var events: [ProviderStreamEvent] = []
        if profile.reasoningDelivery == .none,
           responseParserKinds.contains(where: { $0.contains("reasoning") }),
           let text = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
           !text.isEmpty {
            events.append(.reasoningDelta(text))
        }
        if responseParserKinds.contains("openrouter_reasoning_v1")
            || responseParserKinds.contains("minimax_reasoning_v1") {
            if let details = delta["reasoning_details"] as? [Any] {
                mergeReasoningDetails(details)
                for detail in details {
                    guard let fields = detail as? [String: Any] else { continue }
                    if let text = (fields["text"] as? String) ?? (fields["summary"] as? String), !text.isEmpty {
                        events.append(.reasoningDelta(text))
                    }
                }
            }
        }
        if responseParserKinds.contains("mistral_reasoning_v1"),
           let blocks = delta["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "thinking":
                    let text = (block["thinking"] as? [[String: Any]])?
                        .compactMap { $0["text"] as? String }.joined() ?? ""
                    if !text.isEmpty { events.append(.reasoningDelta(text)) }
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
                default: break
                }
            }
        }
        if !responseParserKinds.isDisjoint(with: Self.annotationCitationParserKinds) {
            let rawAnnotations = (delta["annotations"] as? [[String: Any]])
                ?? ((choice["message"] as? [String: Any])?["annotations"] as? [[String: Any]])
                ?? []
            let citations = rawAnnotations.prefix(ProviderCitation.maximumPerEvent).compactMap(Self.chatCitation)
            if !citations.isEmpty { events.append(.citations(citations)) }
        }
        if responseParserKinds.contains("zhipu_web_search_v1") {
            let rawResults = StreamPathExtractor.extractArray(
                object,
                path: "choices.0.delta.tool_calls.0.web_search.search_result"
            ) ?? []
            let citations = rawResults.prefix(ProviderCitation.maximumPerEvent)
                .compactMap { ($0 as? [String: Any]).flatMap(Self.chatCitation) }
            if !citations.isEmpty { events.append(.citations(citations)) }
        }
        return events
    }

    /// These parsers have a documented OpenAI-Chat annotation result shape.
    /// Other web recipes (Qwen / Moonshot) intentionally do not enter this path:
    /// their observable result contract is different, and parser-name substring
    /// matching would manufacture citation support that the wire does not provide.
    private static let annotationCitationParserKinds: Set<String> = [
        "openai_chat_web_v1",
        "openrouter_web_v1",
    ]

    private static func chatCitation(_ raw: [String: Any]) -> ProviderCitation? {
        let value = (raw["url_citation"] as? [String: Any]) ?? raw
        let rawURL = (value["url"] as? String)
            ?? (value["link"] as? String)
            ?? (value["uri"] as? String)
            ?? ""
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        return ProviderCitation(
            url: url,
            title: value["title"] as? String,
            snippet: (value["snippet"] as? String)
                ?? (value["content"] as? String)
                ?? (value["cited_text"] as? String),
            index: (value["index"] as? NSNumber)?.intValue,
            startIndex: (value["start_index"] as? NSNumber)?.intValue,
            endIndex: (value["end_index"] as? NSNumber)?.intValue
        ).validated()
    }

    private mutating func mergeReasoningDetails(_ rawDetails: [Any]) {
        guard !reasoningDetailsInvalid else { return }
        for raw in rawDetails {
            guard let raw = raw as? [String: Any],
                  let value = ProviderRecipeValue.fromFoundation(raw),
                  let fields = value.objectValue else {
                reasoningDetailsInvalid = true
                reasoningDetails.removeAll()
                return
            }
            let explicit = raw["index"] as? NSNumber
            let index = explicit?.intValue ?? nextReasoningDetailIndex
            guard index >= 0 else {
                reasoningDetailsInvalid = true
                reasoningDetails.removeAll()
                return
            }
            nextReasoningDetailIndex = max(nextReasoningDetailIndex, index + 1)
            if var existing = reasoningDetails[index] {
                for (key, incoming) in fields where key != "index" {
                    if let current = existing[key], current != incoming {
                        if ["data", "text", "summary"].contains(key),
                           let lhs = current.stringValue, let rhs = incoming.stringValue {
                            existing[key] = .string(lhs + rhs)
                        } else {
                            reasoningDetailsInvalid = true
                            reasoningDetails.removeAll()
                            return
                        }
                    } else {
                        existing[key] = incoming
                    }
                }
                reasoningDetails[index] = existing
            } else {
                reasoningDetails[index] = fields
            }
        }
    }

    private mutating func flushOpaqueContinuation() -> [ProviderStreamEvent] {
        guard !reasoningDetailsInvalid, !reasoningDetails.isEmpty else { return [] }
        let details = reasoningDetails.keys.sorted().compactMap { reasoningDetails[$0] }.map(ProviderRecipeValue.object)
        reasoningDetails.removeAll()
        return [.opaqueContinuation(.object(["reasoning_details": .array(details)]))]
    }

    // MARK: - Tool calls

    /// Emits the accumulated calls once, in index order.
    private mutating func flushProposals() -> [ProviderStreamEvent] {
        toolCalls.flush().map { .toolCall($0) }
    }

    // MARK: - usage

    /// Reads cached prompt tokens from wherever this provider puts them, and leaves the field
    /// nil when the provider does not report them at all rather than substituting zero.
    /// A usage object that fails validation yields nil, so an implausible count is dropped
    /// instead of shown.
    static func usage(
        from raw: OpenAICompatibleChunk.Usage,
        profile: ProviderWireProfile
    ) -> ProviderTokenUsage? {
        let cached: Int64?
        switch profile.cachedTokenLocation {
        case .none:
            cached = nil
        case .deepSeekHitMiss:
            cached = raw.promptCacheHitTokens
        case .topLevelCachedTokens:
            cached = raw.cachedTokens
        case .promptTokensDetails:
            cached = raw.promptTokensDetails?.cachedTokens
        }

        let input: Int64
        // DeepSeek guarantees `prompt_cache_hit_tokens + prompt_cache_miss_tokens ==
        // prompt_tokens`, so the input total can be rebuilt when `prompt_tokens` is missing.
        if let prompt = raw.promptTokens {
            input = prompt
        } else if profile.promptTokensEqualCacheHitPlusMiss,
                  let hit = raw.promptCacheHitTokens,
                  let miss = raw.promptCacheMissTokens {
            let sum = hit.addingReportingOverflow(miss)
            guard !sum.overflow else { return nil }
            input = sum.partialValue
        } else {
            return nil
        }
        guard let output = raw.completionTokens,
              input >= 0,
              output >= 0,
              cached.map({ $0 >= 0 && $0 <= input }) ?? true,
              raw.completionTokensDetails?.reasoningTokens.map({ $0 >= 0 && $0 <= output }) ?? true
        else { return nil }
        return ProviderTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cached,
            reasoningOutputTokens: raw.completionTokensDetails?.reasoningTokens
        )
    }

    /// Chunk decoder. `.convertFromSnakeCase` maps the wire's snake_case onto the camelCase
    /// properties below, so no `CodingKeys` block is needed and adding a field stays a one-line
    /// change.
    private static let chunkDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// The subset of an OpenAI-compatible chunk this assembler reads.
///
/// Every field is optional: providers omit whatever is irrelevant to a given frame, and the
/// final usage chunk carries an empty `choices` array.
public struct OpenAICompatibleChunk: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Delta: Decodable, Sendable {
            public var content: String?
            public var reasoningContent: String?
            public var toolCalls: [ToolCallDelta]?
        }

        public struct ToolCallDelta: Decodable, Sendable {
            public struct Function: Decodable, Sendable {
                public var name: String?
                public var arguments: String?
            }

            public var index: Int?
            public var id: String?
            public var type: String?
            public var function: Function?
        }

        public var delta: Delta?
        public var finishReason: String?
    }

    public struct Usage: Decodable, Sendable {
        public struct PromptTokensDetails: Decodable, Sendable {
            public var cachedTokens: Int64?
        }

        public struct CompletionTokensDetails: Decodable, Sendable {
            public var reasoningTokens: Int64?
        }

        public var promptTokens: Int64?
        public var completionTokens: Int64?
        /// DeepSeek's cache split.
        public var promptCacheHitTokens: Int64?
        public var promptCacheMissTokens: Int64?
        /// Moonshot puts cached tokens at the top level of `usage`, not in a details object.
        public var cachedTokens: Int64?
        /// OpenAI's nested prompt token details.
        public var promptTokensDetails: PromptTokensDetails?
        /// Reasoning token counts, reported by DeepSeek and OpenAI alike.
        public var completionTokensDetails: CompletionTokensDetails?
    }

    public var choices: [Choice]?
    public var usage: Usage?
}

/// Assembles fragmented `delta.tool_calls`: id, name and arguments arrive across many chunks,
/// keyed by index, and are only complete once the stream reports a finish reason.
///
/// It is a separate type from the assembler because every OpenAI-compatible caller needs this
/// same reassembly, and one shared implementation is what keeps the fragment-ordering rules
/// from drifting apart between providers.
public struct OpenAICompatibleToolCallAccumulator: Sendable {
    private struct PartialToolCall {
        var id: String?
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: PartialToolCall] = [:]
    private var lastIndex = 0
    private var didFlush = false

    public init() {}

    /// Whether any fragment has been seen, so a caller can tell a tool-calling turn from a
    /// plain answer before the stream ends.
    public var hasProposals: Bool { !partials.isEmpty }

    public mutating func accumulate(_ deltas: [OpenAICompatibleChunk.Choice.ToolCallDelta]) {
        for delta in deltas {
            // Provider-owned result objects may share `delta.tool_calls` with function calls
            // (Zhipu web_search is one example). Unknown-only objects decode to an entirely
            // empty mirror value and must not become an empty executable proposal.
            guard delta.id != nil || delta.type != nil || delta.function != nil else { continue }
            // Some providers omit `index` on continuation fragments: they belong to the call
            // most recently addressed.
            let index = delta.index ?? lastIndex
            lastIndex = index
            var partial = partials[index] ?? PartialToolCall()
            if let id = delta.id, !id.isEmpty, partial.id == nil { partial.id = id }
            // Names arrive in fragments too and are concatenated, never overwritten.
            if let name = delta.function?.name, !name.isEmpty { partial.name += name }
            if let arguments = delta.function?.arguments { partial.arguments += arguments }
            partials[index] = partial
        }
    }

    /// Emits the accumulated calls in index order, which dictionary iteration would not
    /// preserve.
    ///
    /// Flushing is one-shot: fragments that arrive after the finish reason are ignored, so a
    /// stream cannot rewrite a call the caller has already been handed.
    public mutating func flush() -> [ProviderToolCall] {
        guard !didFlush else { return [] }
        didFlush = true
        return partials.keys.sorted().compactMap { index in
            guard let partial = partials[index] else { return nil }
            return ProviderToolCall(
                providerCallID: partial.id,
                name: ToolFunctionNameCodec.decode(partial.name),
                rawArguments: partial.arguments
            )
        }
    }
}
