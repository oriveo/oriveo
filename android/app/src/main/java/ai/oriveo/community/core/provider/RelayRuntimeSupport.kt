package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentSupportInfo
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport

/**
 * Decides what a relay can actually do at runtime.
 *
 * The transport comes from `Provider.relayRequested.transport`. Every attachment, webSearch,
 * imageGeneration and reasoning switch is read from `relayRuntimeConfig.transportEnvelopes` in the
 * published catalog, so those answers can be corrected remotely. Only the protocol-level rules,
 * such as which provider a transport maps onto, are constants in this file.
 *
 * `RelayTransport.Auto` always resolves to `openai_chat_completions`, matching the default used
 * when relay models are synced, so attachment support and runtime routing cannot drift apart.
 */
object RelayRuntimeSupport {

    object TransportKey {
        const val OPENAI_RESPONSES = "openai_responses"
        const val OPENAI_CHAT_COMPLETIONS = "openai_chat_completions"
        const val ANTHROPIC_MESSAGES = "anthropic_messages"
        const val GEMINI_GENERATE_CONTENT = "gemini_generate_content"
    }

    /**
     * Maps a relay transport onto a runtime envelope key, using the same keys the catalog's
     * transportEnvelopes are indexed by. `.Auto` resolves to openai_chat_completions so that
     * there is always a definite envelope even when the user never picked a transport.
     */
    fun envelopeKey(provider: Provider): String? {
        if (provider.kind != ProviderKind.Relay) return null
        return when (provider.relayRequested?.transport ?: RelayTransport.Auto) {
            RelayTransport.Auto -> TransportKey.OPENAI_CHAT_COMPLETIONS
            // Native endpoint has no remote metadata envelope; keep only a routing fallback.
            RelayTransport.LlamaCppNative -> TransportKey.OPENAI_CHAT_COMPLETIONS
            RelayTransport.OpenAIResponses -> TransportKey.OPENAI_RESPONSES
            RelayTransport.OpenAIChatCompletions -> TransportKey.OPENAI_CHAT_COMPLETIONS
            RelayTransport.AnthropicMessages -> TransportKey.ANTHROPIC_MESSAGES
            RelayTransport.GeminiGenerateContent -> TransportKey.GEMINI_GENERATE_CONTENT
        }
    }

    /**
     * The provider a transport nominally corresponds to. Used as the transportPriority when
     * enriching relay models from the catalog.
     */
    fun transportProviderKind(provider: Provider): ProviderKind? {
        val key = envelopeKey(provider) ?: return null
        return providerKindFromBackendKey(
            MetadataClient.relayRuntimeConfig().transportRules[key]?.providerPriority,
        )
    }

    /**
     * Attachment support for the relay's current transport.
     * Returns null when this is not a relay provider, or when the catalog has no envelope for
     * that transport.
     */
    fun attachmentSupport(
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
    ): AttachmentSupportInfo? {
        val key = envelopeKey(provider) ?: return null
        val envelope = runtimeConfig.transportEnvelopes[key] ?: return null
        return AttachmentSupportInfo(
            image = envelope.image,
            video = false,
            nativeFile = envelope.nativeFile,
            textFileInline = envelope.textFileInline,
        )
    }

    fun supportsWebSearch(
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
    ): Boolean {
        val key = envelopeKey(provider) ?: return false
        return runtimeConfig.transportEnvelopes[key]?.webSearch == true
    }

    fun supportsImageGeneration(
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
    ): Boolean {
        val key = envelopeKey(provider) ?: return false
        return runtimeConfig.transportEnvelopes[key]?.imageGeneration == true
    }

    fun supportsReasoning(
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
    ): Boolean {
        val key = envelopeKey(provider) ?: return false
        return runtimeConfig.transportEnvelopes[key]?.reasoning == true
    }

    fun defaultAuthMode(transport: RelayTransport): String? {
        return MetadataClient.relayRuntimeConfig().transportRules[transportKey(transport)]?.defaultAuthMode
    }

    fun codexIdentityDefault(transport: RelayTransport): Boolean {
        return MetadataClient.relayRuntimeConfig().transportRules[transportKey(transport)]?.codexIdentityDefault
            ?: (transport == RelayTransport.OpenAIResponses)
    }

    fun webSearchToolName(transport: RelayTransport): String? {
        return MetadataClient.relayRuntimeConfig().transportRules[transportKey(transport)]?.webSearchToolName
    }

    /* ── Image generation routing ──────────────────────
     * The rules are pinned by the shared routing fixtures, and the fixture tests assert this
     * implementation case by case so the routing table cannot drift.
     */

    /** Image generation routing. The raw values match the snake_case spellings used by the catalog. */
    enum class ImageRoute(val raw: String) {
        /** The image_generation tool inlined into the Responses API, as Codex-style relays expect. */
        InlineResponsesTool("inline_responses_tool"),
        /** The separate `/images/generations` endpoint. */
        ImagesEndpoint("images_endpoint"),
        /** Gemini native modality via responseModalities. */
        GeminiModality("gemini_modality"),
        /** The Anthropic Messages transport cannot generate images at all. */
        Unsupported("unsupported"),
    }

    /**
     * Maps a transport onto its image generation route.
     *
     * A transport rule from the catalog wins when present, so a wrong route can be corrected
     * remotely; otherwise fall back to the static mapping below. There is deliberately no runtime
     * probe: probing burns the user's key and multiplies the number of failure paths.
     */
    fun imageRoute(
        transport: RelayTransport,
        runtimeConfig: MetadataClient.RelayRuntimeConfig? = MetadataClient.relayRuntimeConfig(),
    ): ImageRoute {
        val raw = runtimeConfig?.transportRules[transportKey(transport)]?.imageRoute
        imageRouteFromRaw(raw)?.let { return it }
        return when (transport) {
            RelayTransport.OpenAIResponses -> ImageRoute.InlineResponsesTool
            RelayTransport.GeminiGenerateContent -> ImageRoute.GeminiModality
            RelayTransport.AnthropicMessages -> ImageRoute.Unsupported
            RelayTransport.LlamaCppNative -> ImageRoute.Unsupported
            // Auto is treated exactly as openai_chat_completions.
            RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> ImageRoute.ImagesEndpoint
        }
    }

    /**
     * Recognises a dedicated image model. Prefix match only, case insensitive.
     */
    fun isDedicatedImageModel(modelID: String): Boolean {
        val lower = modelID.lowercase()
        return lower.startsWith("gpt-image-") || lower.startsWith("chatgpt-image-")
    }

    sealed interface PickChatDriverResult {
        data class Success(val modelID: String) : PickChatDriverResult
        /**
         * The relay has no usable chat model; the caller turns this into a friendly "add a chat
         * model first" message.
         */
        data object MissingChatDriverModel : PickChatDriverResult
    }

    /**
     * Picks the upstream primary model id to use when generating images inline through Responses.
     *
     * A `gpt-image-*` id is not a chat model. Put it in body.model and the upstream either ignores
     * it, or the name pollutes the context and nudges the model into drawing a picture on every
     * turn. So when the currently selected model is a dedicated image model, a chat model is
     * chosen as the primary model instead and the image model is demoted to tool.model.
     */
    fun pickChatDriverModelID(
        currentModelID: String,
        models: List<AIModel>,
        defaultModelID: String? = null,
    ): PickChatDriverResult {
        if (!isDedicatedImageModel(currentModelID)) {
            return PickChatDriverResult.Success(currentModelID)
        }
        val acceptable = { model: AIModel ->
            model.isAvailable &&
                !isDedicatedImageModel(model.id) &&
                !model.capabilities.contains(ModelCapability.ImageGen)
        }
        val preferred = defaultModelID?.let { id -> models.firstOrNull { it.id == id } }
            ?: models.firstOrNull { it.isDefault }
        if (preferred != null && acceptable(preferred)) {
            return PickChatDriverResult.Success(preferred.id)
        }
        models.firstOrNull(acceptable)?.let { return PickChatDriverResult.Success(it.id) }
        return PickChatDriverResult.MissingChatDriverModel
    }

    /**
     * Provider overload. Production code passes the provider; tests use the explicit-argument
     * version above.
     */
    fun pickChatDriverModelID(provider: Provider, currentModelID: String): PickChatDriverResult =
        pickChatDriverModelID(
            currentModelID = currentModelID,
            models = provider.models,
            defaultModelID = provider.defaultModel?.id,
        )

    /**
     * Whether `stream = true` has to be forced.
     *
     * Only the imageGen plus inline-Responses-tool combination is forced; everything else respects
     * the user's setting. The reason is measured behaviour: against several relays, a non-streaming
     * `/responses` call returns a truncated image.
     */
    fun shouldForceStream(
        transport: RelayTransport,
        capabilities: List<ModelCapability>,
        runtimeConfig: MetadataClient.RelayRuntimeConfig? = MetadataClient.relayRuntimeConfig(),
    ): Boolean {
        if (!capabilities.contains(ModelCapability.ImageGen)) return false
        val rule = runtimeConfig?.transportRules[transportKey(transport)]
        if (rule != null) return rule.forceStreamForImageGeneration
        return imageRoute(transport, runtimeConfig) == ImageRoute.InlineResponsesTool
    }

    private fun imageRouteFromRaw(raw: String?): ImageRoute? {
        if (raw == null) return null
        // Accept both the catalog's snake_case spelling and the camelCase spelling.
        return when (raw) {
            "inline_responses_tool", "inlineResponsesTool" -> ImageRoute.InlineResponsesTool
            "images_endpoint", "imagesEndpoint" -> ImageRoute.ImagesEndpoint
            "gemini_modality", "geminiModality" -> ImageRoute.GeminiModality
            "unsupported" -> ImageRoute.Unsupported
            else -> null
        }
    }

    private fun transportKey(transport: RelayTransport): String {
        return when (transport) {
            RelayTransport.Auto -> TransportKey.OPENAI_CHAT_COMPLETIONS
            RelayTransport.LlamaCppNative -> TransportKey.OPENAI_CHAT_COMPLETIONS
            RelayTransport.OpenAIResponses -> TransportKey.OPENAI_RESPONSES
            RelayTransport.OpenAIChatCompletions -> TransportKey.OPENAI_CHAT_COMPLETIONS
            RelayTransport.AnthropicMessages -> TransportKey.ANTHROPIC_MESSAGES
            RelayTransport.GeminiGenerateContent -> TransportKey.GEMINI_GENERATE_CONTENT
        }
    }

    private fun providerKindFromBackendKey(raw: String?): ProviderKind? {
        return when (raw) {
            "openAI" -> ProviderKind.OpenAI
            "anthropic" -> ProviderKind.Anthropic
            "gemini" -> ProviderKind.Gemini
            "deepseek" -> ProviderKind.DeepSeek
            "miniMax" -> ProviderKind.MiniMax
            "zhipu" -> ProviderKind.Zhipu
            "qwen" -> ProviderKind.Qwen
            "moonshot" -> ProviderKind.Moonshot
            // If the catalog's relayRuntimeConfig allowlist ships mistral and this mapping were
            // missing, the value would be silently dropped here.
            "mistral" -> ProviderKind.Mistral
            else -> null
        }
    }
}
