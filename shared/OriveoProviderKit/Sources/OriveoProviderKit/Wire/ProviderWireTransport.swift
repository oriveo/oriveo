import Foundation

/// The wire protocol used to talk to a provider endpoint.
///
/// This is the vocabulary shared by every client binding: a transport decides the request
/// shape, the streaming grammar and the response parser, independently of which vendor is
/// behind the endpoint. `basicTextTransports` is the subset that carries ordinary streamed
/// chat; the rest address image and file endpoints.
public enum ProviderWireTransport: String, Codable, Hashable, Sendable, CaseIterable {
    case openAIChat = "openai_chat"
    case openAIResponses = "openai_responses"
    case anthropicMessages = "anthropic_messages"
    case geminiGenerate = "gemini_generate"
    case dashscopeNative = "dashscope_native"
    case openAIImages = "openai_images"
    case geminiImage = "gemini_image"
    case qwenImage = "qwen_image"
    case grokImage = "grok_image"
    case zhipuImage = "zhipu_image"
    case anthropicFiles = "anthropic_files"
    case openAIFiles = "openai_files"

    public static let basicTextTransports: Set<Self> = [
        .openAIChat,
        .openAIResponses,
        .anthropicMessages,
        .geminiGenerate,
    ]
}
