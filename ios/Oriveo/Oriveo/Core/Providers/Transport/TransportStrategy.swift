import Foundation
import OriveoProviderKit

enum TransportKind: String, Sendable, CaseIterable {
    case openaiChat = "openai_chat"
    case openaiResponses = "openai_responses"
    case anthropicMessages = "anthropic_messages"
    case geminiGenerate = "gemini_generate"
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
    var toolCallAccumulator = OpenAICompatibleToolCallAccumulator()
    var protocolToolCallDecoder: (any ToolCallStreamDecoding)?
    var didFinish: Bool = false

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

protocol TransportStrategy: Sendable {
    var kind: TransportKind { get }

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent]
}

