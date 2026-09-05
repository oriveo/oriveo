import Foundation
import OriveoProviderKit

/// `transport=anthropic_messages`:Anthropic Messages API.
struct AnthropicMessagesStrategy: TransportStrategy {
    let kind: TransportKind = .anthropicMessages

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        guard let json = SSEChunkParser.parse(raw) as? [String: Any] else { return [] }
        guard let type = json["type"] as? String else { return [] }

        var events: [StreamEvent] = []

        events.append(contentsOf: ctx.ingestProtocolToolCalls(frame: json) { AnthropicToolAdapter().makeStreamDecoder() })

        if type == "content_block_delta",
           let delta = json["delta"] as? [String: Any] {
            let deltaType = delta["type"] as? String
            if deltaType == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                ctx.accumulatedText += text
                events.append(.delta(text))
            } else if deltaType == "thinking_delta",
                      let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                ctx.accumulatedReasoning += thinking
                events.append(.reasoning(thinking))
            }
            if deltaType == "citations_delta",
               let citation = delta["citation"] as? [String: Any] {
                if let c = parseInlineCitation(citation, shape: shape) {
                    ctx.citationsAccumulator.ingest(c)
                }
            }
        }

        if type == "content_block_start",
           let block = json["content_block"] as? [String: Any] {
            let expectedBlockType = shape?.citationsBlockType ?? "web_search_tool_result"
            if (block["type"] as? String) == expectedBlockType {
                if let items = block["content"] as? [[String: Any]] {
                    for item in items {
                        if let c = parseWebSearchItem(item, shape: shape) {
                            ctx.citationsAccumulator.ingest(c)
                        }
                    }
                }
            }
        }

        if let arrayPath = shape?.citationsArrayPath,
           let arr = StreamPathExtractor.extractArray(json, path: arrayPath) {
            for item in arr {
                if let dict = item as? [String: Any],
                   let c = parseInlineCitation(dict, shape: shape) {
                    ctx.citationsAccumulator.ingest(c)
                }
            }
        }

        return events
    }

    static func flushToolCalls(ctx: inout StreamContext) -> [StreamEvent] {
        ctx.flushProtocolToolCalls()
    }

    private func parseWebSearchItem(
        _ item: [String: Any],
        shape: MetadataClient.StreamShape?
    ) -> Citation? {
        let urlField = shape?.citationUrlField ?? "url"
        let titleField = shape?.citationTitleField ?? "title"
        let snippetField = shape?.citationSnippetField ?? "cited_text"

        let url = (item[urlField] as? String) ?? (item["url"] as? String) ?? ""
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Citation(
            url: url,
            title: (item[titleField] as? String) ?? (item["title"] as? String),
            snippet: (item[snippetField] as? String) ?? (item["cited_text"] as? String),
            faviconUrl: item["favicon"] as? String,
            index: item["index"] as? Int,
            startIndex: nil,
            endIndex: nil
        )
    }

    private func parseInlineCitation(_ c: [String: Any], shape: MetadataClient.StreamShape?) -> Citation? {
        let urlField = shape?.citationUrlField ?? "url"
        let titleField = shape?.citationTitleField ?? "title"
        let snippetField = shape?.citationSnippetField ?? "cited_text"
        let urlRaw = (c[urlField] as? String) ?? (c["url"] as? String) ?? ""
        let url = urlRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        return Citation(
            url: url,
            title: (c[titleField] as? String) ?? (c["title"] as? String),
            snippet: (c[snippetField] as? String) ?? (c["cited_text"] as? String),
            faviconUrl: nil,
            index: c["document_index"] as? Int,
            startIndex: c["start_char_index"] as? Int,
            endIndex: c["end_char_index"] as? Int
        )
    }
}
