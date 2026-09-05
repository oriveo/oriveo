import Foundation
import OriveoProviderKit

/// ```
/// {"choices":[{"delta":{"content":"...", "reasoning_content":"..."},
/// ```
struct OpenAIChatStrategy: TransportStrategy {
    let kind: TransportKind = .openaiChat

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        guard let json = SSEChunkParser.parse(raw) else { return [] }

        var events: [StreamEvent] = []

        let contentNode = StreamPathExtractor.extract(json, path: "choices.0.delta.content")
        if let content = contentNode as? String, !content.isEmpty {
            ctx.accumulatedText += content
            events.append(.delta(content))
        } else if let folded = OpenAIChatContentBlocks.fold(contentNode) {
            if !folded.reasoning.isEmpty {
                ctx.accumulatedReasoning += folded.reasoning
                events.append(.reasoning(folded.reasoning))
            }
            if !folded.text.isEmpty {
                ctx.accumulatedText += folded.text
                events.append(.delta(folded.text))
            }
        }

        if let overridePath = shape?.reasoningDeltaPath {
            if let reasoning = StreamPathExtractor.extractString(json, path: overridePath),
               !reasoning.isEmpty {
                ctx.accumulatedReasoning += reasoning
                events.append(.reasoning(reasoning))
            }
        } else {
            let reasoning = StreamPathExtractor.extractString(
                json, path: "choices.0.delta.reasoning_content"
            ) ?? StreamPathExtractor.extractString(
                json, path: "choices.0.delta.reasoning"
            )
            if let reasoning, !reasoning.isEmpty {
                ctx.accumulatedReasoning += reasoning
                events.append(.reasoning(reasoning))
            }
        }

        if let arrayPath = shape?.citationsArrayPath,
           let citations = parseCitations(from: json, arrayPath: arrayPath, shape: shape) {
            for c in citations {
                ctx.citationsAccumulator.ingest(c)
            }
        }

        if let rawDeltas = StreamPathExtractor.extractArray(json, path: "choices.0.delta.tool_calls"),
           let deltas = Self.decodeToolCallDeltas(rawDeltas) {
            ctx.toolCallAccumulator.accumulate(deltas)
        }
        if let finishReason = StreamPathExtractor.extractString(json, path: "choices.0.finish_reason"),
           !finishReason.isEmpty {
            events.append(contentsOf: Self.flushToolCalls(ctx: &ctx))
        }

        return events
    }

    static func flushToolCalls(ctx: inout StreamContext) -> [StreamEvent] {
        let calls = ctx.toolCallAccumulator.flush()
        return calls.isEmpty ? [] : [.toolCallDeltas(calls)]
    }

    private static func decodeToolCallDeltas(_ raw: [Any]) -> [OpenAICompatibleChunk.Choice.ToolCallDelta]? {
        let functionOnly = raw.compactMap { item -> [String: Any]? in
            guard let dict = item as? [String: Any], dict["function"] is [String: Any] else { return nil }
            return dict
        }
        guard !functionOnly.isEmpty,
              JSONSerialization.isValidJSONObject(functionOnly),
              let data = try? JSONSerialization.data(withJSONObject: functionOnly),
              let deltas = try? JSONDecoder().decode([OpenAICompatibleChunk.Choice.ToolCallDelta].self, from: data)
        else { return nil }
        return deltas
    }

    private func parseCitations(
        from json: Any?,
        arrayPath: String,
        shape: MetadataClient.StreamShape?
    ) -> [Citation]? {
        guard let arr = StreamPathExtractor.extractArray(json, path: arrayPath) else { return nil }
        let urlField = shape?.citationUrlField ?? "url"
        let titleField = shape?.citationTitleField ?? "title"
        let snippetField = shape?.citationSnippetField ?? "snippet"

        var results: [Citation] = []
        for item in arr {
            guard let dict = item as? [String: Any] else { continue }

            let baseDict: [String: Any]
            if let type = dict["type"] as? String,
               type == "url_citation",
               let inner = dict["url_citation"] as? [String: Any] {
                baseDict = inner
            } else {
                baseDict = dict
            }

            let url = (baseDict[urlField] as? String)
                ?? (StreamPathExtractor.extractString(dict, path: urlField))
                ?? (baseDict["url"] as? String)
                ?? (baseDict["link"] as? String)
                ?? (baseDict["uri"] as? String)
                ?? ""
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let title = (baseDict[titleField] as? String)
                ?? (StreamPathExtractor.extractString(dict, path: titleField))
                ?? (baseDict["title"] as? String)
            let snippet = (baseDict[snippetField] as? String)
                ?? (StreamPathExtractor.extractString(dict, path: snippetField))
                ?? (baseDict["snippet"] as? String)
                ?? (baseDict["content"] as? String)
                ?? (baseDict["cited_text"] as? String)
            let faviconUrl = (baseDict["icon"] as? String)
                ?? (baseDict["favicon"] as? String)
            let index = baseDict["index"] as? Int
            results.append(Citation(
                url: url,
                title: title,
                snippet: snippet,
                faviconUrl: faviconUrl,
                index: index,
                startIndex: baseDict["start_index"] as? Int,
                endIndex: baseDict["end_index"] as? Int
            ))
        }
        return results.isEmpty ? nil : results
    }
}
