import Foundation

/// Stream assembler for the OpenAI Responses, Anthropic Messages and Gemini
/// `generateContent` protocols.
///
/// OpenAI Chat has its own assembler because its grammar is different enough that sharing one
/// would mean a switch in every branch. The three protocols here are event-based and converge
/// on the same output: text, reasoning, tool calls, citations, usage and exactly one terminal
/// event.
public struct ProviderTextStreamAssembler: Sendable {
    /// True once the protocol's own terminal event has been seen. `finish` requires it, so a
    /// connection that simply stops mid-answer is reported as truncated rather than complete.
    public private(set) var isDone = false

    private let transport: ProviderWireTransport
    private let responseParserKinds: Set<String>
    private var usage: ProviderTokenUsage?
    private var finishReason: String?
    private var toolCalls: [Int: ToolCallAccumulator] = [:]
    private var anthropicThinking = ""
    private var anthropicSignature = ""

    private struct ToolCallAccumulator: Sendable {
        var id: String?
        var name = ""
        var arguments = ""
        var signature: String?
    }

    public init(
        transport: ProviderWireTransport,
        responseParserKinds: Set<String> = []
    ) throws {
        guard transport == .openAIResponses
                || transport == .anthropicMessages
                || transport == .geminiGenerate else {
            throw ProviderTextWireRequestError.unsupportedTransport(transport)
        }
        self.transport = transport
        self.responseParserKinds = responseParserKinds
    }

    public mutating func ingest(_ line: String) throws -> [ProviderStreamEvent] {
        guard !isDone, !line.isEmpty, !line.hasPrefix(":"), line.hasPrefix("data:") else {
            return []
        }
        var payload = line.dropFirst("data:".count)
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }
        if payload == "[DONE]" {
            // Responses-compatible relays may additionally send [DONE], but it is not enough
            // to replace response.completed as the protocol terminal receipt.
            return []
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if object["error"] != nil || object["type"] as? String == "error" {
            throw ProviderStreamWireError.upstreamError
        }
        switch transport {
        case .openAIResponses:
            return ingestResponses(object)
        case .anthropicMessages:
            return ingestAnthropic(object)
        case .geminiGenerate:
            return ingestGemini(object)
        default:
            return []
        }
    }

    public mutating func finish() throws -> [ProviderStreamEvent] {
        guard isDone else { throw ProviderStreamWireError.truncated }
        var events: [ProviderStreamEvent] = []
        if let usage { events.append(.usage(usage)) }
        events.append(.finished(reason: finishReason))
        return events
    }

    private mutating func ingestResponses(_ object: [String: Any]) -> [ProviderStreamEvent] {
        let type = object["type"] as? String
        if hasCitationParser,
           type == "response.output_text.annotation.added",
           let annotation = object["annotation"] as? [String: Any],
           let citation = Self.responsesCitation(annotation) {
            return [.citations([citation])]
        }
        if hasCitationParser,
           type == "response.output_item.done",
           let item = object["item"] as? [String: Any],
           item["type"] as? String != "function_call" {
            let citations = Self.responsesCitations(item)
            if !citations.isEmpty { return [.citations(citations)] }
        }
        if type == "response.created",
           let response = object["response"] as? [String: Any],
           let id = response["id"] as? String, !id.isEmpty {
            return [.opaqueContinuation(.object(["previous_response_id": .string(id)]))]
        }
        if (type == "response.reasoning_summary_text.delta" || type == "response.reasoning_text.delta"),
           let delta = object["delta"] as? String, !delta.isEmpty {
            return [.reasoningDelta(delta)]
        }
        if type == "response.output_text.delta", let delta = object["delta"] as? String {
            return delta.isEmpty ? [] : [.textDelta(delta)]
        }
        if type == "response.output_item.added",
           let index = Self.int(object["output_index"]),
           let item = object["item"] as? [String: Any],
           item["type"] as? String == "function_call" {
            toolCalls[index] = ToolCallAccumulator(
                id: item["call_id"] as? String ?? item["id"] as? String,
                name: item["name"] as? String ?? "",
                arguments: item["arguments"] as? String ?? "",
                signature: nil
            )
            return []
        }
        if type == "response.function_call_arguments.delta",
           let index = Self.int(object["output_index"]),
           let delta = object["delta"] as? String {
            toolCalls[index, default: ToolCallAccumulator()].arguments += delta
            return []
        }
        if type == "response.output_item.done",
           let index = Self.int(object["output_index"]),
           let item = object["item"] as? [String: Any],
           item["type"] as? String == "function_call" {
            var call = toolCalls.removeValue(forKey: index) ?? ToolCallAccumulator()
            call.id = item["call_id"] as? String ?? item["id"] as? String ?? call.id
            call.name = item["name"] as? String ?? call.name
            if let arguments = item["arguments"] as? String, !arguments.isEmpty { call.arguments = arguments }
            return call.name.isEmpty ? [] : [.toolCall(.init(
                providerCallID: call.id,
                name: ToolFunctionNameCodec.decode(call.name),
                rawArguments: call.arguments.isEmpty ? "{}" : call.arguments
            ))]
        }
        guard type == "response.completed",
              let response = object["response"] as? [String: Any] else { return [] }
        finishReason = response["status"] as? String ?? "completed"
        if let raw = response["usage"] as? [String: Any] {
            usage = Self.responsesUsage(raw)
        }
        isDone = true
        return []
    }

    private mutating func ingestAnthropic(_ object: [String: Any]) -> [ProviderStreamEvent] {
        let type = object["type"] as? String
        if type == "message_start",
           let message = object["message"] as? [String: Any],
           let raw = message["usage"] as? [String: Any] {
            usage = Self.anthropicUsage(input: raw, output: nil)
        }
        if type == "content_block_start",
           let index = Self.int(object["index"]),
           let block = object["content_block"] as? [String: Any] {
            if hasCitationParser,
               block["type"] as? String == "web_search_tool_result" {
                let citations = Self.anthropicCitations(block)
                return citations.isEmpty ? [] : [.citations(citations)]
            }
            switch block["type"] as? String {
            case "tool_use":
                toolCalls[index] = ToolCallAccumulator(
                    id: block["id"] as? String,
                    name: block["name"] as? String ?? "",
                    arguments: "",
                    signature: nil
                )
            case "thinking":
                anthropicThinking = block["thinking"] as? String ?? ""
                anthropicSignature = block["signature"] as? String ?? ""
            default: break
            }
            return []
        }
        if type == "content_block_delta",
           let delta = object["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String,
           !text.isEmpty {
            return [.textDelta(text)]
        }
        if type == "content_block_delta",
           let index = Self.int(object["index"]),
           let delta = object["delta"] as? [String: Any] {
            switch delta["type"] as? String {
            case "citations_delta" where hasCitationParser:
                guard let raw = delta["citation"] as? [String: Any],
                      let citation = Self.anthropicCitation(raw) else { return [] }
                return [.citations([citation])]
            case "thinking_delta":
                let text = delta["thinking"] as? String ?? ""
                anthropicThinking += text
                return text.isEmpty ? [] : [.reasoningDelta(text)]
            case "signature_delta":
                anthropicSignature += delta["signature"] as? String ?? ""
                return []
            case "input_json_delta":
                toolCalls[index, default: ToolCallAccumulator()].arguments += delta["partial_json"] as? String ?? ""
                return []
            default: break
            }
        }
        if type == "content_block_stop", let index = Self.int(object["index"]) {
            if let call = toolCalls.removeValue(forKey: index), !call.name.isEmpty {
                var events: [ProviderStreamEvent] = []
                if !anthropicThinking.isEmpty, !anthropicSignature.isEmpty {
                    events.append(.opaqueContinuation(.object([
                        "thinking": .string(anthropicThinking),
                        "signature": .string(anthropicSignature),
                    ])))
                }
                events.append(.toolCall(.init(
                    providerCallID: call.id,
                    name: ToolFunctionNameCodec.decode(call.name),
                    rawArguments: call.arguments.isEmpty ? "{}" : call.arguments
                )))
                return events
            }
            return []
        }
        if type == "message_delta" {
            if let delta = object["delta"] as? [String: Any] {
                finishReason = delta["stop_reason"] as? String ?? finishReason
            }
            if let output = object["usage"] as? [String: Any] {
                usage = Self.anthropicUsage(input: nil, output: output, previous: usage)
            }
        }
        if type == "message_stop" {
            isDone = true
        }
        return []
    }

    private mutating func ingestGemini(_ object: [String: Any]) -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        if let candidates = object["candidates"] as? [[String: Any]],
           let first = candidates.first {
            if let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if (part["thought"] as? Bool) == true {
                        if let text = part["text"] as? String, !text.isEmpty {
                            events.append(.reasoningDelta(text))
                        }
                        continue
                    }
                    if let text = part["text"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
                    if let function = part["functionCall"] as? [String: Any],
                       let name = function["name"] as? String, !name.isEmpty {
                        let arguments = ProviderRecipeValue.fromFoundation(function["args"] ?? [:])
                            .map(Self.compactJSONString) ?? "{}"
                        let signature = part["thoughtSignature"] as? String
                        if let signature, !signature.isEmpty {
                            events.append(.opaqueContinuation(.object(["thought_signature": .string(signature)])))
                        }
                        events.append(.toolCall(.init(
                            providerCallID: function["id"] as? String,
                            name: ToolFunctionNameCodec.decode(name),
                            rawArguments: arguments,
                            providerSignature: signature
                        )))
                    }
                }
            }
            if hasCitationParser {
                let citations = Self.geminiCitations(first)
                if !citations.isEmpty { events.append(.citations(citations)) }
            }
            if let reason = first["finishReason"] as? String, !reason.isEmpty {
                finishReason = reason
                isDone = true
            }
        }
        if let raw = object["usageMetadata"] as? [String: Any] {
            usage = Self.geminiUsage(raw)
        }
        return events
    }

    private var hasCitationParser: Bool {
        let supported: Set<String>
        switch transport {
        case .openAIResponses:
            supported = ["openai_responses_web_v1", "grok_web_search_v1"]
        case .anthropicMessages:
            supported = ["anthropic_web_search_v1", "minimax_anthropic_web_v1"]
        case .geminiGenerate:
            supported = ["gemini_google_search_v1"]
        default:
            supported = []
        }
        return !responseParserKinds.isDisjoint(with: supported)
    }

    private static func responsesCitation(_ raw: [String: Any]) -> ProviderCitation? {
        let type = raw["type"] as? String
        guard type == nil || type == "url_citation" else { return nil }
        return citation(
            raw,
            urlKeys: ["url", "uri", "link"],
            snippetKeys: ["snippet", "cited_text", "content"],
            indexKeys: ["index"]
        )
    }

    private static func responsesCitations(_ item: [String: Any]) -> [ProviderCitation] {
        guard let content = item["content"] as? [[String: Any]] else { return [] }
        return content.flatMap { block in
            (block["annotations"] as? [[String: Any]] ?? []).compactMap(responsesCitation)
        }.prefix(ProviderCitation.maximumPerEvent).map { $0 }
    }

    private static func anthropicCitations(_ block: [String: Any]) -> [ProviderCitation] {
        (block["content"] as? [[String: Any]] ?? [])
            .prefix(ProviderCitation.maximumPerEvent).compactMap(anthropicCitation)
    }

    private static func anthropicCitation(_ raw: [String: Any]) -> ProviderCitation? {
        citation(
            raw,
            urlKeys: ["url", "uri", "link"],
            snippetKeys: ["cited_text", "snippet", "content"],
            indexKeys: ["document_index", "index"],
            startKeys: ["start_char_index", "start_index"],
            endKeys: ["end_char_index", "end_index"]
        )
    }

    private static func geminiCitations(_ candidate: [String: Any]) -> [ProviderCitation] {
        guard let metadata = candidate["groundingMetadata"] as? [String: Any],
              let chunks = metadata["groundingChunks"] as? [[String: Any]] else { return [] }
        var ranges: [Int: (Int?, Int?)] = [:]
        for support in metadata["groundingSupports"] as? [[String: Any]] ?? [] {
            guard let indices = support["groundingChunkIndices"] as? [Int],
                  let segment = support["segment"] as? [String: Any] else { continue }
            for index in indices {
                ranges[index] = (int(segment["startIndex"]), int(segment["endIndex"]))
            }
        }
        return chunks.prefix(ProviderCitation.maximumPerEvent).enumerated().compactMap { index, chunk in
            let web = chunk["web"] as? [String: Any] ?? chunk
            guard var result = citation(
                web,
                urlKeys: ["uri", "url", "link"],
                snippetKeys: ["snippet", "content"],
                indexKeys: []
            ) else { return nil }
            result.index = index
            result.startIndex = ranges[index]?.0
            result.endIndex = ranges[index]?.1
            return result.validated()
        }
    }

    private static func citation(
        _ raw: [String: Any],
        urlKeys: [String],
        snippetKeys: [String],
        indexKeys: [String],
        startKeys: [String] = ["start_index"],
        endKeys: [String] = ["end_index"]
    ) -> ProviderCitation? {
        let url = firstString(in: raw, keys: urlKeys).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        return ProviderCitation(
            url: url,
            title: nonEmptyString(raw["title"]),
            snippet: firstOptionalString(in: raw, keys: snippetKeys),
            index: firstInt(in: raw, keys: indexKeys),
            startIndex: firstInt(in: raw, keys: startKeys),
            endIndex: firstInt(in: raw, keys: endKeys)
        ).validated()
    }

    private static func firstString(in raw: [String: Any], keys: [String]) -> String {
        firstOptionalString(in: raw, keys: keys) ?? ""
    }

    private static func firstOptionalString(in raw: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { nonEmptyString(raw[$0]) }.first
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func firstInt(in raw: [String: Any], keys: [String]) -> Int? {
        keys.lazy.compactMap { int(raw[$0]) }.first
    }

    private static func responsesUsage(_ raw: [String: Any]) -> ProviderTokenUsage? {
        guard let input = int64(raw["input_tokens"]),
              let output = int64(raw["output_tokens"]),
              input >= 0, output >= 0 else { return nil }
        let cached = (raw["input_tokens_details"] as? [String: Any])
            .flatMap { int64($0["cached_tokens"]) }
        let reasoning = (raw["output_tokens_details"] as? [String: Any])
            .flatMap { int64($0["reasoning_tokens"]) }
        guard cached.map({ $0 >= 0 && $0 <= input }) ?? true,
              reasoning.map({ $0 >= 0 && $0 <= output }) ?? true else { return nil }
        return ProviderTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cached,
            reasoningOutputTokens: reasoning
        )
    }

    private static func anthropicUsage(
        input: [String: Any]?,
        output: [String: Any]?,
        previous: ProviderTokenUsage? = nil
    ) -> ProviderTokenUsage? {
        let rawInput = input.flatMap { int64($0["input_tokens"]) } ?? previous?.inputTokens
        let cacheRead = input.flatMap { int64($0["cache_read_input_tokens"]) }
            ?? previous?.cachedInputTokens
        let cacheCreate = input.flatMap { int64($0["cache_creation_input_tokens"]) } ?? 0
        let outputTokens = output.flatMap { int64($0["output_tokens"]) }
            ?? previous?.outputTokens ?? 0
        guard let rawInput, rawInput >= 0, cacheCreate >= 0, outputTokens >= 0 else { return nil }
        let total = rawInput.addingReportingOverflow(cacheCreate)
        guard !total.overflow,
              cacheRead.map({ $0 >= 0 && $0 <= total.partialValue }) ?? true else { return nil }
        return ProviderTokenUsage(
            inputTokens: total.partialValue,
            outputTokens: outputTokens,
            cachedInputTokens: cacheRead
        )
    }

    private static func geminiUsage(_ raw: [String: Any]) -> ProviderTokenUsage? {
        guard let input = int64(raw["promptTokenCount"]),
              let output = int64(raw["candidatesTokenCount"]),
              input >= 0, output >= 0 else { return nil }
        let cached = int64(raw["cachedContentTokenCount"])
        let reasoning = int64(raw["thoughtsTokenCount"])
        guard cached.map({ $0 >= 0 && $0 <= input }) ?? true,
              reasoning.map({ $0 >= 0 }) ?? true else { return nil }
        return ProviderTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cached,
            reasoningOutputTokens: reasoning
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            let result = number.int64Value
            return NSNumber(value: result) == number ? result : nil
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int? { int64(value).flatMap(Int.init(exactly:)) }

    private static func compactJSONString(_ value: ProviderRecipeValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value.foundationValue, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
