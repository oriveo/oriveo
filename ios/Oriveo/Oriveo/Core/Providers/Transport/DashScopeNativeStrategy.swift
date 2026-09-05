import Foundation
import OriveoProviderKit

/// - reasoning:`output.choices[0].message.reasoning_content`
/// - citations:`output.search_info.search_results[]`({site_name, icon, index, title, url})
struct DashScopeNativeStrategy: TransportStrategy {
    let kind: TransportKind = .dashscopeNative

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        guard let json = SSEChunkParser.parse(raw) as? [String: Any] else { return [] }

        var events: [StreamEvent] = []

        if let choices = StreamPathExtractor.extractArray(json, path: "output.choices") {
            if let first = choices.first as? [String: Any],
               let message = first["message"] as? [String: Any] {
                if let content = message["content"] as? String, !content.isEmpty {
                    ctx.accumulatedText += content
                    events.append(.delta(content))
                }
                if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
                    ctx.accumulatedReasoning += reasoning
                    events.append(.reasoning(reasoning))
                }
            }
        } else if let text = StreamPathExtractor.extractString(json, path: "output.text") {
            let delta = diffSuffix(previous: ctx.accumulatedText, latest: text)
            if !delta.isEmpty {
                ctx.accumulatedText = text
                events.append(.delta(delta))
            }
        }

        // citations:output.search_info.search_results[]
        let arrayPath = shape?.citationsArrayPath ?? "output.search_info.search_results"
        if let results = StreamPathExtractor.extractArray(json, path: arrayPath) {
            let urlField = shape?.citationUrlField ?? "url"
            let titleField = shape?.citationTitleField ?? "title"

            for item in results {
                guard let dict = item as? [String: Any] else { continue }
                let url = (dict[urlField] as? String)
                    ?? (dict["url"] as? String)
                    ?? ""
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                ctx.citationsAccumulator.ingest(Citation(
                    url: trimmed,
                    title: (dict[titleField] as? String) ?? (dict["title"] as? String),
                    snippet: (dict["snippet"] as? String) ?? (dict["content"] as? String),
                    faviconUrl: (dict["icon"] as? String) ?? (dict["site_name"] as? String),
                    index: dict["index"] as? Int,
                    startIndex: nil,
                    endIndex: nil
                ))
            }
        }

        return events
    }

    private func diffSuffix(previous: String, latest: String) -> String {
        if previous.isEmpty { return latest }
        if latest.hasPrefix(previous) {
            return String(latest.dropFirst(previous.count))
        }
        return latest
    }
}
