package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.ProviderKind

/**
 * How a route treats uploading original files.
 *
 * - [Always]: go native according to the model allowlist and the [AttachmentRouter] rules; a rejection upstream is final.
 * - [AlwaysWithTextFallback]: the routing rules are exactly those of [Always], but when the upstream rejects a request carrying file
 *   blocks before producing any output, resend once with the files injected as text (see [NativeFileFallback]). For relays and
 *   subscription routes: whether the other end accepts file blocks varies from site to site and cannot be known beforehand.
 * - [Off]: no native upload.
 */
enum class NativeFileMode { Always, AlwaysWithTextFallback, Off }

/**
 * How an outbound route carries file attachments. Each route is declared once here, and request-building code only refers to the route
 * instead of passing by hand "whether native upload is allowed / which wrapper to use / whose rules to route by".
 *
 * The constructor is private: a new route must add a subclass in this file before [AttachmentDelivery.plan] will accept it.
 *
 * @property hasNativeFileBlocks Whether this route's request builder can emit original file blocks (input_file / document / inlineData).
 * @property nativeFiles The native upload mode; separate from the previous property, it is [NativeFileMode.Off] when the route has native blocks but does not enable them.
 * @property wrapper The wrapper format for text injection; it is part of the bytes on the wire.
 * @property routingProvider Whose rules (the per-file byte limit) [AttachmentRouter] uses when deciding native upload.
 */
sealed class AttachmentTransportProfile private constructor(
    val hasNativeFileBlocks: Boolean,
    val nativeFiles: NativeFileMode,
    val wrapper: AttachmentWrapperVersion,
    val routingProvider: ProviderKind,
) {
    /**
     * The one-line placeholder written into the text for each image when this route cannot send images, so the model knows an image did not arrive;
     * null for routes that can carry images.
     */
    open val imagePlaceholderText: String? get() = null

    /** Whether this turn's files may go up natively; when false they are all delivered as text. */
    val allowsNativeFiles: Boolean get() = hasNativeFileBlocks && nativeFiles != NativeFileMode.Off

    /** The same route, but without file blocks this time: a fallback resend, or a connection already known not to accept file blocks. The wrapper format is unchanged. */
    fun withoutNativeFiles(): AttachmentTransportProfile = if (allowsNativeFiles) TextOnly(this) else this

    /** See [withoutNativeFiles]. */
    data class TextOnly(val base: AttachmentTransportProfile) : AttachmentTransportProfile(
        hasNativeFileBlocks = false,
        nativeFiles = NativeFileMode.Off,
        wrapper = base.wrapper,
        routingProvider = base.routingProvider,
    ) {
        override val imagePlaceholderText: String? get() = base.imagePlaceholderText
    }

    /** OpenAI Chat Completions family (content parts): the wrapper format follows the owning provider. OpenRouter and DeepSeek each have a separate entry. */
    data class ChatCompletions(val provider: ProviderKind) : AttachmentTransportProfile(
        hasNativeFileBlocks = false,
        nativeFiles = NativeFileMode.Off,
        wrapper = AttachmentWrapperVersion.resolve(provider),
        routingProvider = provider,
    )

    /** OpenRouter Chat Completions: a `file` part (file_data is a data URI), which OpenRouter forwards upstream or parses on its behalf. */
    data object OpenRouterChat : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.Always,
        wrapper = AttachmentWrapperVersion.resolve(ProviderKind.OpenRouter),
        routingProvider = ProviderKind.OpenRouter,
    )

    /** DeepSeek Chat Completions: content accepts only a string, so attachments are folded into the text. */
    data object DeepSeekChat : AttachmentTransportProfile(
        hasNativeFileBlocks = false,
        nativeFiles = NativeFileMode.Off,
        wrapper = AttachmentWrapperVersion.MarkdownV1,
        routingProvider = ProviderKind.DeepSeek,
    ) {
        override val imagePlaceholderText: String? get() = "[Image omitted: unsupported by DeepSeek]"
    }

    /** OpenAI Responses (direct API key): input_file. */
    data object OpenAIResponses : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.Always,
        wrapper = AttachmentWrapperVersion.XmlV1,
        routingProvider = ProviderKind.OpenAI,
    )

    /** The Responses route of a subscription (ChatGPT / Grok): input_file; the subscription backend is unverified, so a rejection falls back to text. */
    data object SubscriptionResponses : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.AlwaysWithTextFallback,
        wrapper = AttachmentWrapperVersion.XmlV1,
        routingProvider = ProviderKind.OpenAI,
    )

    /** A relay's Responses connection: whether a relay passes input_file through varies by site, and a rejection falls back to text. */
    data object RelayOpenAIResponses : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.AlwaysWithTextFallback,
        wrapper = AttachmentWrapperVersion.XmlV1,
        routingProvider = ProviderKind.OpenAI,
    )

    /**
     * The Anthropic-compatible endpoint the MiniMax web search recipe uses: the request format is Messages, the wrapper format still follows MiniMax (markdown),
     * and files are always delivered as text.
     */
    data object MiniMaxAnthropicMessages : AttachmentTransportProfile(
        hasNativeFileBlocks = false,
        nativeFiles = NativeFileMode.Off,
        wrapper = AttachmentWrapperVersion.resolve(ProviderKind.MiniMax),
        routingProvider = ProviderKind.MiniMax,
    )

    /** Anthropic Messages (direct API key): document block. */
    data object AnthropicMessages : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.Always,
        wrapper = AttachmentWrapperVersion.XmlV1,
        routingProvider = ProviderKind.Anthropic,
    )

    /** A relay's Anthropic Messages connection. */
    data object RelayAnthropicMessages : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.AlwaysWithTextFallback,
        wrapper = AttachmentWrapperVersion.XmlV1,
        routingProvider = ProviderKind.Anthropic,
    )

    /** A relay's Gemini generateContent connection. */
    data object RelayGeminiGenerateContent : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.AlwaysWithTextFallback,
        wrapper = AttachmentWrapperVersion.XmlV1,
        routingProvider = ProviderKind.Gemini,
    )

    /** Gemini generateContent (direct API key): inlineData. */
    data object GeminiGenerateContent : AttachmentTransportProfile(
        hasNativeFileBlocks = true,
        nativeFiles = NativeFileMode.Always,
        wrapper = AttachmentWrapperVersion.XmlV1,
        routingProvider = ProviderKind.Gemini,
    )

    /** Gemini Interactions (the endpoint_route of the web search recipe): files are delivered as text; images go as inlineData parts, the same as generateContent. */
    data object GeminiInteractions : AttachmentTransportProfile(
        hasNativeFileBlocks = false,
        nativeFiles = NativeFileMode.Off,
        wrapper = AttachmentWrapperVersion.resolve(ProviderKind.Gemini),
        routingProvider = ProviderKind.Gemini,
    )

    /** A relay's llama.cpp native `/completion`: the whole conversation is folded into one prompt string, so images can only leave a placeholder. */
    data object LlamaCppNative : AttachmentTransportProfile(
        hasNativeFileBlocks = false,
        nativeFiles = NativeFileMode.Off,
        wrapper = AttachmentWrapperVersion.resolve(ProviderKind.Relay),
        routingProvider = ProviderKind.Relay,
    ) {
        override val imagePlaceholderText: String? get() = "[Image omitted: this route sends text only]"
    }
}
