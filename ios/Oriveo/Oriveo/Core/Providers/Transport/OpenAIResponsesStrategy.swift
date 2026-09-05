import Foundation
import OriveoProviderKit

struct OpenAIResponsesStrategy: TransportStrategy {
    let kind: TransportKind = .openaiResponses

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        guard let json = SSEChunkParser.parse(raw) as? [String: Any] else { return [] }
        guard let type = json["type"] as? String else { return [] }

        var events: [StreamEvent] = []

        events.append(contentsOf: ctx.ingestProtocolToolCalls(frame: json) { OpenAIResponsesToolAdapter().makeStreamDecoder() })

        if type == "response.output_text.delta",
           let delta = json["delta"] as? String, !delta.isEmpty {
            ctx.accumulatedText += delta
            events.append(.delta(delta))
        }

        // Reasoning arrives under more than one event name; all of them carry the same delta.
        if (type == "response.reasoning.delta"
            || type == "response.reasoning_summary_text.delta"
            || type == "response.reasoning_summary.delta"),
           let delta = json["delta"] as? String, !delta.isEmpty {
            ctx.accumulatedReasoning += delta
            events.append(.reasoning(delta))
        }

        if type == "response.output_text.annotation.added",
           let annotation = json["annotation"] as? [String: Any],
           let citation = parseUrlCitation(annotation) {
            ctx.citationsAccumulator.ingest(citation)
        }

        if type == "response.output_item.done",
           let item = json["item"] as? [String: Any] {
            if let content = item["content"] as? [[String: Any]] {
                for block in content {
                    if let annotations = block["annotations"] as? [[String: Any]] {
                        for a in annotations {
                            if let citation = parseUrlCitation(a) {
                                ctx.citationsAccumulator.ingest(citation)
                            }
                        }
                    }
                }
            }
        }

        if let arrayPath = shape?.citationsArrayPath,
           let arr = StreamPathExtractor.extractArray(json, path: arrayPath) {
            for item in arr {
                if let dict = item as? [String: Any], let citation = parseUrlCitation(dict) {
                    ctx.citationsAccumulator.ingest(citation)
                }
            }
        }

        return events
    }

    static func flushToolCalls(ctx: inout StreamContext) -> [StreamEvent] {
        ctx.flushProtocolToolCalls()
    }

    private func parseUrlCitation(_ a: [String: Any]) -> Citation? {
        let type = a["type"] as? String
        guard type == nil || type == "url_citation" else { return nil }
        guard let url = (a["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return nil }
        return Citation(
            url: url,
            title: a["title"] as? String,
            snippet: a["snippet"] as? String,
            faviconUrl: a["favicon"] as? String,
            index: a["index"] as? Int,
            startIndex: a["start_index"] as? Int,
            endIndex: a["end_index"] as? Int
        )
    }
}
