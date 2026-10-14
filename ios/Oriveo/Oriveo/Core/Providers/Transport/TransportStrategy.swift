import Foundation
import OriveoProviderKit

enum TransportKind: String, Sendable, CaseIterable {
    case openaiChat = "openai_chat"
    case openaiResponses = "openai_responses"
    case anthropicMessages = "anthropic_messages"
    case geminiGenerate = "gemini_generate"
    /// Reachable only through a server-side transport override. It is sent by the same GeminiService; whether this turn uses Interactions or
    /// generateContent is decided by `GeminiService.interactionsRecipe`.
    case geminiInteractions = "gemini_interactions"
    case dashscopeNative = "dashscope_native"
    case openaiImages = "openai_images"
    case geminiImage = "gemini_image"
    case qwenImage = "qwen_image"
    case grokImage = "grok_image"
    case zhipuImage = "zhipu_image"
    case anthropicFiles = "anthropic_files"
    case openaiFiles = "openai_files"
}

enum EndpointKind: String, Sendable {
    case chat
    case responses
    case images
    case embeddings
    case files
}

struct UnsupportedTransportError: Error, Sendable {
    let kind: String
    let modelID: String?
}

struct StreamContext: Sendable {
    var accumulatedText: String = ""
    var accumulatedReasoning: String = ""
    var citationsAccumulator = CitationAccumulator()
    var toolCallAccumulator = OpenAICompatibleToolCallAccumulator(decodesFunctionNames: false)
    var protocolToolCallDecoder: (any ToolCallStreamDecoding)?
    var didFinish: Bool = false
    /// Evidence that the server really ran a web search (read by the relay web-search probe; chat does not read it, so chat output is unaffected).
    var webSearchEvidence = WebSearchEvidence()
    /// Relay Chat streams only: when the stream shape's citation path points at `choices.0.message.*`, also read
    /// `choices.0.delta.*` from streaming frames (OpenAI Chat streaming puts web-search annotations on the delta).
    /// Set only by relay streams; direct providers are unchanged.
    var readsDeltaCitations = false

    mutating func ingestProtocolToolCalls(
        frame: [String: Any],
        makeDecoder: () -> any ToolCallStreamDecoding
    ) -> [StreamEvent] {
        var decoder = protocolToolCallDecoder ?? makeDecoder()
        let calls = decoder.ingest(frame: frame)
        protocolToolCallDecoder = decoder
        return calls.isEmpty ? [] : [.toolCallDeltas(calls)]
    }

    mutating func flushProtocolToolCalls() -> [StreamEvent] {
        guard var decoder = protocolToolCallDecoder else { return [] }
        let calls = decoder.finish()
        protocolToolCallDecoder = decoder
        return calls.isEmpty ? [] : [.toolCallDeltas(calls)]
    }
}

/// Web-search evidence recognized by each protocol parser (fixture `web-probe.v1.json`, `evidence`).
/// `ran` means a search ran but did not necessarily yield citations (a completed Responses web_search_call,
/// a Messages result array that is present but empty, a non-empty Gemini groundingMetadata);
/// `urls` holds the citation URLs in arrival order (not de-duplicated).
struct WebSearchEvidence: Sendable, Equatable {
    var ran = false
    var urls: [String] = []

    var isEmpty: Bool { !ran && urls.isEmpty }

    mutating func note(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { urls.append(trimmed) }
    }
}

protocol TransportStrategy: Sendable {
    var kind: TransportKind { get }

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent]
}

