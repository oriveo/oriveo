import Foundation

/// How a route sends files as native file blocks.
enum NativeFileMode: Equatable {
    /// Routes natively according to the model allow-list and `AttachmentRouter`; an upstream rejection is a failure, with no fallback.
    case always
    /// Same routing rules as `.always`; if the upstream rejects the request before producing any output,
    /// the request is resent once with the files injected as text (see `NativeFileFallback`).
    /// For routes where there is no guarantee the other end accepts file blocks.
    case alwaysWithTextFallback
    case off
}

/// What an outbound route declares about attachments: whether files can go out as native file blocks,
/// which wrapper format text injection uses, and which provider the native size threshold belongs to.
///
/// These values are declared in one table, `AttachmentTransport.profile`; each message builder only
/// reports which route it is, so a wrong literal cannot slip past the compiler.
struct AttachmentTransportProfile: Equatable {
    /// Owner of the native route: decides `AttachmentRouter`'s per-file size threshold.
    let provider: ProviderKind
    /// Wrapper format used once a file has been extracted to text.
    let wrapper: AttachmentWrapperVersion
    /// Whether this route's message builder can assemble files into native file blocks in the request format.
    let supportsNativeFiles: Bool
    /// Native file mode for this turn. Only meaningful when `supportsNativeFiles` is true.
    let nativeFiles: NativeFileMode
    /// Whether this route's message builder can assemble images into image parts in the request format.
    /// A route that is false (plain text only) always writes `imagePlaceholderText` for every image; whether a true route sends the image depends only on the vision projection's outbound.
    let supportsImageParts: Bool
    /// When an image does not go into the request, this placeholder is written into the body for each image: a text-only route always writes it; a route that can carry image parts
    /// only writes it when the vision projection's outbound=placeholder and the builder hands the image over. nil means the route writes no placeholder and the builder handles images itself.
    let imagePlaceholderText: String?
    /// Whether this route's message builder can assemble videos into video parts in the request format (Gemini inlineData, Moonshot video_url).
    let supportsVideoParts: Bool

    /// When a video does not go into the request, this placeholder is written into the body for each video, without the file name: a route with an image placeholder derives it by
    /// swapping Image for Video; a route that sends images natively but takes no video (such as Anthropic Messages) writes the generic text.
    /// nil only appears when the route can send video parts.
    var videoPlaceholderText: String? {
        if let imagePlaceholderText {
            return imagePlaceholderText.replacingOccurrences(of: "Image", with: "Video")
        }
        return supportsVideoParts ? nil : textOnlyRouteVideoPlaceholder
    }

    /// The mode actually in effect. A route whose builder never assembles native blocks must be `.off`,
    /// otherwise a file routed away would reach neither the text nor the request.
    var effectiveNativeFiles: NativeFileMode { supportsNativeFiles ? nativeFiles : .off }

    /// Whether any file may be routed to the native group.
    var sendsNativeFiles: Bool { effectiveNativeFiles != .off }

    fileprivate init(
        provider: ProviderKind,
        wrapper: AttachmentWrapperVersion,
        supportsNativeFiles: Bool = false,
        nativeFiles: NativeFileMode = .off,
        supportsImageParts: Bool = true,
        imagePlaceholderText: String? = nil,
        supportsVideoParts: Bool = false
    ) {
        self.provider = provider
        self.wrapper = wrapper
        self.supportsNativeFiles = supportsNativeFiles
        self.nativeFiles = nativeFiles
        self.supportsImageParts = supportsImageParts
        self.imagePlaceholderText = imagePlaceholderText
        self.supportsVideoParts = supportsVideoParts
    }

    #if DEBUG
    /// For tests to build arbitrary combinations; production code only gets a profile through `AttachmentTransport.profile`.
    static func forTesting(
        provider: ProviderKind,
        wrapper: AttachmentWrapperVersion,
        supportsNativeFiles: Bool = false,
        nativeFiles: NativeFileMode = .off,
        supportsImageParts: Bool = true,
        imagePlaceholderText: String? = nil,
        supportsVideoParts: Bool = false
    ) -> AttachmentTransportProfile {
        AttachmentTransportProfile(
            provider: provider,
            wrapper: wrapper,
            supportsNativeFiles: supportsNativeFiles,
            nativeFiles: nativeFiles,
            supportsImageParts: supportsImageParts,
            imagePlaceholderText: imagePlaceholderText,
            supportsVideoParts: supportsVideoParts
        )
    }
    #endif
}

/// Per-route native file upload modes: one line per route, independent of each other.
///
/// The four official direct routes have each been checked against the real provider, which accepts native file
/// blocks and reads the file content, so they are `.always`. Subscription and Relay routes of the same protocol
/// route the same way, but whether the other end accepts file blocks varies by site, so they are `.alwaysWithTextFallback`.
/// If one route misbehaves, switch only its own line to `.off` and its files return to text extraction.
/// A mode only decides how far a file is allowed to go; which file actually goes native is still decided by the
/// model's `nativeFileMimes` / `pdfNativeDefault` and `AttachmentRouter`'s size threshold, so a model without an
/// allow-list produces no native block even when the route is on.
enum NativeFileUploadSwitch {
    static let openAIResponses = NativeFileMode.always
    /// Not verified against the real provider: the subscription route uses the ChatGPT backend, whose accepted part types may differ from the official API.
    static let codexSubscription = NativeFileMode.alwaysWithTextFallback
    /// Not verified against the real provider: the Grok subscription goes through the cli-chat-proxy Responses endpoint, whose accepted part types may differ from the official API.
    static let grokSubscription = NativeFileMode.alwaysWithTextFallback
    /// Not verified against the real provider: whether a relay passes input_file through varies by site.
    static let relayOpenAIResponses = NativeFileMode.alwaysWithTextFallback
    static let anthropicMessages = NativeFileMode.always
    /// Not verified against the real provider: whether a relay passes document blocks through varies by site.
    static let relayAnthropicMessages = NativeFileMode.alwaysWithTextFallback
    static let geminiGenerateContent = NativeFileMode.always
    /// Not verified against the real provider: whether a relay passes inlineData through varies by site.
    static let relayGeminiGenerateContent = NativeFileMode.alwaysWithTextFallback
    static let openRouterChat = NativeFileMode.always
    /// Tool-loop legs on OpenRouter also send Chat Completions, with file blocks shaped like `openRouterChat`.
    /// This leg itself has not been verified against the real provider.
    static let openRouterToolLoop = NativeFileMode.always
}

/// Placeholder a text-only route writes into the body for each image, so the model knows the user attached
/// an image that was not delivered instead of assuming there was none.
let textOnlyRouteImagePlaceholder = "[Image omitted: this route sends text only]"

/// Generic video placeholder written when a video does not go into the request and the route has no image placeholder of its own.
let textOnlyRouteVideoPlaceholder = "[Video omitted: this route sends text only]"

/// Every outbound route. Adding a route means adding a case; the `profile` switch does not compile until it is declared.
enum AttachmentTransport: Hashable {
    // OpenAI
    case openAIChat
    case openAIResponses
    case codexSubscription
    case relayOpenAIChat
    case relayOpenAIResponses
    /// llama.cpp native `/completion`: the request is a single plain-text prompt with no message array, so there are no file blocks.
    case relayLlamaCppNative
    // Anthropic
    case anthropicMessages
    case relayAnthropicMessages
    // Gemini
    case geminiGenerateContent
    case relayGeminiGenerateContent
    /// Gemini Interactions: each message is a single text part with no native file blocks; images arrive as a placeholder.
    case geminiInteractions
    // OpenRouter
    case openRouterChat
    // Grok
    case grokChat
    case grokResponses
    case grokSubscription
    // MiniMax
    case miniMaxChat
    case miniMaxAnthropicWeb
    // Other OpenAI-compatible services
    case deepSeekChat
    case qwenChat
    case moonshotChat
    case zhipuChat
    case siliconFlowChat
    case mistralChat
    case groqChat
    case togetherChat
    case fireworksChat
    /// Tool-loop legs: messages are first converted to provider-independent `ToolLoopMessage`s, and the wrapper format
    /// still follows the provider actually executing. Only the OpenRouter leg carries native file blocks (it sends
    /// Chat Completions `file` parts); legs for other providers carry only text and images.
    case toolLoop(ProviderKind)

    var profile: AttachmentTransportProfile {
        switch self {
        case .openAIChat:
            return .init(provider: .openAI, wrapper: .xmlV1)
        case .openAIResponses:
            return .init(provider: .openAI, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.openAIResponses)
        case .codexSubscription:
            return .init(provider: .openAI, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.codexSubscription)
        case .relayOpenAIChat:
            return .init(provider: .openAI, wrapper: .xmlV1)
        case .relayOpenAIResponses:
            return .init(provider: .openAI, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.relayOpenAIResponses)
        case .relayLlamaCppNative:
            return .init(provider: .openAI, wrapper: .xmlV1, supportsImageParts: false, imagePlaceholderText: textOnlyRouteImagePlaceholder)

        case .anthropicMessages:
            return .init(provider: .anthropic, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.anthropicMessages)
        case .relayAnthropicMessages:
            return .init(provider: .anthropic, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.relayAnthropicMessages)

        case .geminiGenerateContent:
            return .init(provider: .gemini, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.geminiGenerateContent, supportsVideoParts: true)
        case .relayGeminiGenerateContent:
            return .init(provider: .gemini, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.relayGeminiGenerateContent, supportsVideoParts: true)
        case .geminiInteractions:
            // The image part shape for this route is not established (the recipe and replay fixtures only cover text parts), so no image is sent and a placeholder stands in.
            return .init(provider: .gemini, wrapper: .xmlV1, supportsImageParts: false, imagePlaceholderText: textOnlyRouteImagePlaceholder)

        case .openRouterChat:
            return .init(provider: .openRouter, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.openRouterChat)

        case .grokChat, .grokResponses:
            return .init(provider: .grok, wrapper: .xmlV1)
        case .grokSubscription:
            return .init(provider: .grok, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.grokSubscription)

        case .miniMaxChat, .miniMaxAnthropicWeb:
            // Both routes' builders only send a string content.
            return .init(provider: .miniMax, wrapper: .markdownV1, imagePlaceholderText: textOnlyRouteImagePlaceholder)

        case .deepSeekChat:
            return .init(
                provider: .deepseek,
                wrapper: .markdownV1,
                imagePlaceholderText: "[Image omitted: unsupported by DeepSeek]"
            )
        case .qwenChat:
            return .init(provider: .qwen, wrapper: .markdownV1)
        case .moonshotChat:
            return .init(provider: .moonshot, wrapper: .markdownV1, supportsVideoParts: true)
        case .zhipuChat:
            return .init(provider: .zhipu, wrapper: .markdownV1)
        case .siliconFlowChat:
            return .init(provider: .siliconFlow, wrapper: .markdownV1)
        case .mistralChat:
            return .init(provider: .mistral, wrapper: .xmlV1)
        case .groqChat:
            return .init(provider: .groq, wrapper: .xmlV1)
        case .togetherChat:
            return .init(provider: .together, wrapper: .xmlV1)
        case .fireworksChat:
            return .init(provider: .fireworks, wrapper: .xmlV1)

        case .toolLoop(.openRouter):
            return .init(provider: .openRouter, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: NativeFileUploadSwitch.openRouterToolLoop)
        case .toolLoop(let provider):
            // The tool leg also goes out over that provider's Chat route: when that route sends text only, images get the same placeholder it declares.
            let chatRoute: AttachmentTransport? = switch provider { // capability-lint-allow R2: AttachmentTransport.profile is a wire profile table without model context; tool-leg message conversion sends no images by wire shape
            case .deepseek: .deepSeekChat // capability-lint-allow R2: AttachmentTransport.profile is a wire profile table without model context; tool-leg message conversion sends no images by wire shape
            case .miniMax: .miniMaxChat // capability-lint-allow R2: AttachmentTransport.profile is a wire profile table without model context; tool-leg message conversion sends no images by wire shape
            default: nil
            }
            return .init(
                provider: provider, wrapper: AttachmentWrapperVersion.resolve(provider: provider),
                supportsImageParts: chatRoute == nil,
                imagePlaceholderText: chatRoute?.profile.imagePlaceholderText
            )
        }
    }
}
