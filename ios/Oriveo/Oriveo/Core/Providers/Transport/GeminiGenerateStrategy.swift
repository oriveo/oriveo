import Foundation
import OriveoProviderKit

/// `transport=gemini_generate`:Gemini `generateContent` / `streamGenerateContent`.
struct GeminiGenerateStrategy: TransportStrategy {
    let kind: TransportKind = .geminiGenerate

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        guard let json = SSEChunkParser.parse(raw) as? [String: Any] else { return [] }

        var events: [StreamEvent] = []

        events.append(contentsOf: ctx.ingestProtocolToolCalls(frame: json) { GeminiToolAdapter().makeStreamDecoder() })

        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else { return events }

        if let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                if (part["thought"] as? Bool) == true {
                    ctx.accumulatedReasoning += text
                    events.append(.reasoning(text))
                } else {
                    ctx.accumulatedText += text
                    events.append(.delta(text))
                }
            }
        }

        // citations:groundingMetadata.groundingChunks[]
        let arrayPath = shape?.citationsArrayPath ?? "candidates.0.groundingMetadata.groundingChunks"
        if let chunks = StreamPathExtractor.extractArray(json, path: arrayPath) {
            let urlField = shape?.citationUrlField ?? "web.uri"
            let titleField = shape?.citationTitleField ?? "web.title"
            for chunk in chunks {
                guard let dict = chunk as? [String: Any] else { continue }
                let url = StreamPathExtractor.extractString(dict, path: urlField)
                    ?? (dict["uri"] as? String)
                    ?? ""
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let title = StreamPathExtractor.extractString(dict, path: titleField)
                    ?? (dict["title"] as? String)
                let snippet: String? = nil

                ctx.citationsAccumulator.ingest(Citation(
                    url: trimmed,
                    title: title,
                    snippet: snippet,
                    faviconUrl: nil,
                    index: nil,
                    startIndex: nil,
                    endIndex: nil
                ))
            }
        }

        if let supports = StreamPathExtractor.extractArray(json, path: "candidates.0.groundingMetadata.groundingSupports"),
           let chunksArr = StreamPathExtractor.extractArray(json, path: "candidates.0.groundingMetadata.groundingChunks") {
            for support in supports {
                guard let s = support as? [String: Any],
                      let segment = s["segment"] as? [String: Any],
                      let indices = s["groundingChunkIndices"] as? [Int] else { continue }
                let startIdx = segment["startIndex"] as? Int
                let endIdx = segment["endIndex"] as? Int

                for chunkIdx in indices {
                    guard chunkIdx >= 0, chunkIdx < chunksArr.count,
                          let chunkDict = chunksArr[chunkIdx] as? [String: Any] else { continue }
                    let url: String = {
                        if let urlString = StreamPathExtractor.extractString(chunkDict, path: "web.uri") {
                            return urlString
                        }
                        return (chunkDict["uri"] as? String) ?? ""
                    }()
                    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    let title = StreamPathExtractor.extractString(chunkDict, path: "web.title")
                        ?? (chunkDict["title"] as? String)

                    ctx.citationsAccumulator.ingest(Citation(
                        url: trimmed,
                        title: title,
                        snippet: nil,
                        faviconUrl: nil,
                        index: chunkIdx,
                        startIndex: startIdx,
                        endIndex: endIdx
                    ))
                }
            }
        }

        return events
    }

    static func flushToolCalls(ctx: inout StreamContext) -> [StreamEvent] {
        ctx.flushProtocolToolCalls()
    }
}
