import Foundation

/// Per-provider quirks of the OpenAI-compatible wire protocol.
///
/// The OpenAI Chat Completions shape is only a family resemblance: providers agree on the
/// envelope and then differ in the details. A profile captures exactly those differences so
/// that a single assembler can serve every OpenAI-compatible provider instead of one
/// hand-written parser per vendor.
///
/// A profile only describes how bytes arrive, never what a model can do. "Whether this model
/// supports thinking" is a model capability; "when a provider does emit reasoning, it arrives
/// in `reasoning_content` or inside `<think>` tags" is wire shape, and only the latter belongs
/// here.
///
/// Per-model knobs stay out of the profile as well: reasoning effort, thinking budget, web
/// search parameters and response stream shape are resolved from the capability runtime for a
/// concrete model, because two models behind the same provider id routinely disagree about
/// them. `stream_options.include_usage` is the one exception - it is a property of the
/// endpoint rather than of the model, so it is requested unconditionally.
public struct ProviderWireProfile: Sendable, Equatable {
    public enum BuiltinTool: String, Sendable, Equatable, Hashable {
        case imageGeneration = "image_generation"
    }

    /// Stable identifier, matching the provider key used elsewhere in the client.
    public var id: String
    /// Human-readable provider name, as the vendor spells it.
    public var displayName: String
    /// Base URL that `chatCompletionsPath` is resolved against. Relay endpoints supply their own.
    public var defaultBaseURL: URL
    /// Chat path appended to the base URL. Defaults to `chat/completions`.
    public var chatCompletionsPath: String
    /// How this provider delivers reasoning text when a model produces any.
    public var reasoningDelivery: ReasoningDelivery
    /// Where cached prompt tokens appear in the usage object. `.none` means the provider never
    /// reports them, which is different from reporting zero.
    public var cachedTokenLocation: CachedTokenLocation
    /// True when the provider guarantees
    /// `prompt_cache_hit_tokens + prompt_cache_miss_tokens == prompt_tokens`.
    /// DeepSeek does, which lets the input total be reconstructed when `prompt_tokens` is absent.
    public var promptTokensEqualCacheHitPlusMiss: Bool
    /// True when the provider accepts image parts in OpenAI-compatible chat message content.
    /// Whether a given model accepts images is a separate, per-model question.
    public var supportsImageParts: Bool
    /// Provider-side tools this endpoint runs itself, exposed as ordinary tool entries on the wire.
    public var builtinTools: Set<BuiltinTool>

    public init(
        id: String,
        displayName: String,
        defaultBaseURL: URL,
        chatCompletionsPath: String = "chat/completions",
        reasoningDelivery: ReasoningDelivery = .none,
        cachedTokenLocation: CachedTokenLocation = .none,
        promptTokensEqualCacheHitPlusMiss: Bool = false,
        supportsImageParts: Bool = false
    ) {
        self.init(
            id: id,
            displayName: displayName,
            defaultBaseURL: defaultBaseURL,
            chatCompletionsPath: chatCompletionsPath,
            reasoningDelivery: reasoningDelivery,
            cachedTokenLocation: cachedTokenLocation,
            promptTokensEqualCacheHitPlusMiss: promptTokensEqualCacheHitPlusMiss,
            supportsImageParts: supportsImageParts,
            builtinTools: []
        )
    }

    public init(
        id: String,
        displayName: String,
        defaultBaseURL: URL,
        chatCompletionsPath: String = "chat/completions",
        reasoningDelivery: ReasoningDelivery = .none,
        cachedTokenLocation: CachedTokenLocation = .none,
        promptTokensEqualCacheHitPlusMiss: Bool = false,
        supportsImageParts: Bool = false,
        builtinTools: Set<BuiltinTool>
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.chatCompletionsPath = chatCompletionsPath
        self.reasoningDelivery = reasoningDelivery
        self.cachedTokenLocation = cachedTokenLocation
        self.promptTokensEqualCacheHitPlusMiss = promptTokensEqualCacheHitPlusMiss
        self.supportsImageParts = supportsImageParts
        self.builtinTools = builtinTools
    }

    public enum ReasoningDelivery: Sendable, Equatable {
        /// Reasoning text never appears on this provider's chat stream.
        case none
        /// Delivered in `choices[].delta.reasoning_content` (DeepSeek, Moonshot, SiliconFlow).
        case reasoningContentField
        /// Delivered inline in the answer body, wrapped in `<think>...</think>` (MiniMax).
        /// `ThinkingTagParser` splits it back out so the tags never reach the rendered answer.
        case inlineThinkTags
    }

    public enum CachedTokenLocation: Sendable, Equatable {
        /// The provider does not report cached prompt tokens at all.
        case none
        /// DeepSeek: `usage.prompt_cache_hit_tokens` / `usage.prompt_cache_miss_tokens`.
        case deepSeekHitMiss
        /// Moonshot: `cached_tokens` sits at the top level of `usage`.
        /// Reading OpenAI's `prompt_tokens_details.cached_tokens` here would report a constant
        /// zero, because Moonshot never populates that nested object.
        case topLevelCachedTokens
        /// OpenAI and compatible endpoints: `usage.prompt_tokens_details.cached_tokens`.
        case promptTokensDetails
    }
}

// MARK: - Built-in provider profiles

extension ProviderWireProfile {
    public static let deepSeek = ProviderWireProfile(
        id: "deepseek",
        displayName: "DeepSeek",
        defaultBaseURL: URL(string: "https://api.deepseek.com/v1")!,
        reasoningDelivery: .reasoningContentField,
        cachedTokenLocation: .deepSeekHitMiss,
        promptTokensEqualCacheHitPlusMiss: true
    )

    /// Moonshot (Kimi). `api.moonshot.ai` bills in USD, `api.moonshot.cn` in CNY; the two are
    /// separate hosts rather than separate paths, so the account decides the base URL.
    public static let moonshot = ProviderWireProfile(
        id: "moonshot",
        displayName: "Moonshot",
        defaultBaseURL: URL(string: "https://api.moonshot.ai/v1")!,
        reasoningDelivery: .reasoningContentField,
        cachedTokenLocation: .topLevelCachedTokens
    )

    /// Qwen through its OpenAI-compatible Chat Completions endpoint.
    ///
    /// The default here is the international DashScope host; an account in another region
    /// supplies its own base URL. Qwen reports reasoning in `reasoning_content`, the same way
    /// DeepSeek and Moonshot do.
    public static let qwen = ProviderWireProfile(
        id: "qwen",
        displayName: "Qwen",
        defaultBaseURL: URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")!,
        reasoningDelivery: .reasoningContentField,
        supportsImageParts: true
    )

    public static let openAI = ProviderWireProfile(
        id: "openAI",
        displayName: "OpenAI",
        defaultBaseURL: URL(string: "https://api.openai.com/v1")!,
        cachedTokenLocation: .promptTokensDetails,
        supportsImageParts: true,
        builtinTools: [.imageGeneration]
    )

    public static let groq = ProviderWireProfile(
        id: "groq",
        displayName: "Groq",
        defaultBaseURL: URL(string: "https://api.groq.com/openai/v1")!
    )

    public static let openRouter = ProviderWireProfile(
        id: "openRouter",
        displayName: "OpenRouter",
        defaultBaseURL: URL(string: "https://openrouter.ai/api/v1")!
    )

    public static let siliconFlow = ProviderWireProfile(
        id: "siliconFlow",
        displayName: "SiliconFlow",
        defaultBaseURL: URL(string: "https://api.siliconflow.cn/v1")!
    )

    public static let togetherAI = ProviderWireProfile(
        id: "togetherAI",
        displayName: "Together AI",
        defaultBaseURL: URL(string: "https://api.together.xyz/v1")!
    )

    public static let fireworksAI = ProviderWireProfile(
        id: "fireworksAI",
        displayName: "Fireworks AI",
        defaultBaseURL: URL(string: "https://api.fireworks.ai/inference/v1")!
    )

    /// MiniMax streams reasoning inline in the answer body; `ThinkingTagParser` separates it.
    public static let miniMax = ProviderWireProfile(
        id: "miniMax",
        displayName: "MiniMax",
        defaultBaseURL: URL(string: "https://api.minimax.io/v1")!,
        reasoningDelivery: .inlineThinkTags
    )

    public static let zhipu = ProviderWireProfile(
        id: "zhipu",
        displayName: "Z.ai",
        defaultBaseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!
    )

    public static let grok = ProviderWireProfile(
        id: "grok",
        displayName: "Grok",
        defaultBaseURL: URL(string: "https://api.x.ai/v1")!
    )

    public static let mistral = ProviderWireProfile(
        id: "mistral",
        displayName: "Mistral",
        defaultBaseURL: URL(string: "https://api.mistral.ai/v1")!
    )

    /// A user-supplied OpenAI-compatible endpoint. Nothing about its quirks is known ahead of
    /// time, so the profile claims nothing: no reasoning delivery and no cached-token location,
    /// which keeps unmeasured token counts absent rather than reported as zero.
    public static func relay(
        id: String = "relay",
        displayName: String = "Relay",
        baseURL: URL
    ) -> ProviderWireProfile {
        ProviderWireProfile(id: id, displayName: displayName, defaultBaseURL: baseURL)
    }

    /// Looks up a built-in profile by id; returns nil for anything else, including relays,
    /// which are built with `relay(...)` instead.
    public static func builtIn(id: String) -> ProviderWireProfile? {
        builtInProfiles[id]
    }

    /// Every built-in profile, keyed by its id.
    public static let builtInProfiles: [String: ProviderWireProfile] = [
        openRouter.id: openRouter,
        deepSeek.id: deepSeek,
        moonshot.id: moonshot,
        qwen.id: qwen,
        openAI.id: openAI,
        groq.id: groq,
        siliconFlow.id: siliconFlow,
        togetherAI.id: togetherAI,
        fireworksAI.id: fireworksAI,
        miniMax.id: miniMax,
        zhipu.id: zhipu,
        grok.id: grok,
        mistral.id: mistral,
    ]
}
