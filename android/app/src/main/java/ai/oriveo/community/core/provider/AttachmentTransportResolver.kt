package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.transport.TransportKind

/**
 * Which outbound route a send will take.
 *
 * Each Service uses the verdicts here to choose its route when sending; before sending, the composer uses [resolve] to get the same answer
 * and asks [ai.oriveo.community.core.attachments.AttachmentDelivery] whether this turn's attachments fit.
 * It reads only the in-memory connection config and the metadata snapshot; it neither touches the network nor suspends.
 */
object AttachmentTransportResolver {

    /**
     * @property transport The route declaration.
     * @property model The model this route's request builder actually works attachments out from: text-injection routes use the selected model,
     *   official / relay routes with native file blocks use the entry in the metadata catalog (null when it cannot be found).
     */
    data class Route(val transport: AttachmentTransportProfile, val model: AIModel?)

    // ── Verdicts called by each Service when sending ──

    /**
     * The route declaration for Chat Completions style messages: DeepSeek's content accepts only strings and OpenRouter's content parts
     * can carry original files, so each has its own entry.
     */
    fun chatCompletions(kind: ProviderKind): AttachmentTransportProfile = when (kind) {
        ProviderKind.DeepSeek -> AttachmentTransportProfile.DeepSeekChat
        ProviderKind.OpenRouter -> AttachmentTransportProfile.OpenRouterChat
        else -> AttachmentTransportProfile.ChatCompletions(kind)
    }

    /**
     * The outbound protocol of an OpenAI-compatible Service.
     *
     * @param subscriptionTransport The protocol a subscription connection is locked to; null when not a subscription. Subscription models are not in the catalog,
     *   so when it has a value [catalogTransport] is ignored.
     */
    fun openAICompatibleTransport(subscriptionTransport: String?, catalogTransport: String?): TransportKind = when {
        subscriptionTransport == TransportKind.OpenAIResponses.wireValue -> TransportKind.OpenAIResponses
        subscriptionTransport != null -> TransportKind.OpenAIChat
        else -> TransportKind.fromWireValue(catalogTransport) ?: TransportKind.OpenAIChat
    }

    /** The outbound protocol of official OpenAI (API key): a custom endpoint only has Chat Completions, and the official endpoint defaults to Responses. */
    fun openAIOfficialTransport(usesOfficialApi: Boolean, catalogTransport: String?): TransportKind =
        if (!usesOfficialApi || TransportKind.fromWireValue(catalogTransport) == TransportKind.OpenAIChat) {
            TransportKind.OpenAIChat
        } else {
            TransportKind.OpenAIResponses
        }

    /** The protocol a relay connection actually uses: Auto and unconfigured both land on Chat Completions. */
    fun relayTransport(requested: RelayRequestedConfig?): RelayTransport =
        requested?.transport?.takeIf { it != RelayTransport.Auto } ?: RelayTransport.OpenAIChatCompletions

    // ── Whole resolution before sending ──

    /**
     * Resolves the route of this send from the connection, the model and the request options.
     *
     * Returning null means it cannot be decided synchronously right now, and the caller must not block on that: image generation models have their own dispatch,
     * and the route depends on the metadata catalog, which has not arrived yet.
     */
    fun resolve(
        provider: Provider,
        model: AIModel,
        webSearchEnabled: Boolean,
        reasoningMode: ReasoningMode,
    ): Route? {
        if (ModelCapability.ImageGen in model.capabilities) return null
        return when (provider.kind) {
            ProviderKind.Relay -> relayRoute(provider, model)
            else -> officialRoute(provider, model, webSearchEnabled, reasoningMode)
        }
    }

    /**
     * Every route this send could take when the request options (web search, reasoning tier) are not yet known; null if any combination cannot be resolved.
     * Entry points that know the options use [routesFor].
     *
     * A send with a tool loop (MCP) always builds its leg request messages as Chat Completions, so direct routes count that as
     * a possibility too. The caller may block only when none of the possible routes fits.
     */
    fun possibleRoutes(provider: Provider, model: AIModel): List<Route>? {
        val routes = LinkedHashSet<Route>()
        for (web in listOf(false, true)) {
            for (mode in ReasoningMode.entries) {
                routes += resolve(provider, model, web, mode) ?: return null
            }
        }
        routes += Route(chatCompletions(provider.kind), model)
        return routes.toList()
    }

    /**
     * The routes this send could take when the request options are known: the one resolved from the options, plus, when [toolLoopPossible] is true,
     * the tool loop's leg route (leg requests always build messages as Chat Completions, and whether the loop takes over is only decided after sending).
     * Null when it cannot be resolved.
     */
    fun routesFor(
        provider: Provider,
        model: AIModel,
        webSearchEnabled: Boolean,
        reasoningMode: ReasoningMode,
        toolLoopPossible: Boolean,
    ): List<Route>? {
        val routes = LinkedHashSet<Route>()
        routes += resolve(provider, model, webSearchEnabled, reasoningMode) ?: return null
        if (toolLoopPossible) {
            routes += Route(chatCompletions(provider.kind), model)
        }
        return routes.toList()
    }

    private fun relayRoute(provider: Provider, model: AIModel): Route? =
        when (relayTransport(provider.relayRequested)) {
            RelayTransport.LlamaCppNative -> Route(AttachmentTransportProfile.LlamaCppNative, model)
            RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> Route(chatCompletions(ProviderKind.Relay), model)
            RelayTransport.OpenAIResponses ->
                catalogRoute(AttachmentTransportProfile.RelayOpenAIResponses, model.id, ProviderKind.OpenAI)
            RelayTransport.AnthropicMessages ->
                catalogRoute(AttachmentTransportProfile.RelayAnthropicMessages, model.id, ProviderKind.Anthropic)
            RelayTransport.GeminiGenerateContent ->
                catalogRoute(AttachmentTransportProfile.RelayGeminiGenerateContent, model.id, ProviderKind.Gemini)
        }

    private fun officialRoute(
        provider: Provider,
        model: AIModel,
        webSearchEnabled: Boolean,
        reasoningMode: ReasoningMode,
    ): Route? {
        val kind = provider.kind
        // A subscription has only one path, decided by the connection shape; its request builder uses the selected model.
        CapabilityControlResolution.subscriptionFinalTransport(provider, model)?.let { subscriptionTransport ->
            return when (openAICompatibleTransport(subscriptionTransport, catalogTransport = null)) {
                TransportKind.OpenAIResponses -> Route(AttachmentTransportProfile.SubscriptionResponses, model)
                else -> Route(chatCompletions(kind), model)
            }
        }
        return when (kind) {
            ProviderKind.Qwen, ProviderKind.OpenRouter -> Route(chatCompletions(kind), model)
            ProviderKind.Anthropic -> catalogRoute(AttachmentTransportProfile.AnthropicMessages, model.id, kind)
            ProviderKind.Gemini -> {
                if (!catalogReady(kind)) return null
                if (GeminiService.interactionsRoute(model.id, webSearchEnabled, reasoningMode) != null) {
                    Route(AttachmentTransportProfile.GeminiInteractions, model)
                } else {
                    catalogRoute(AttachmentTransportProfile.GeminiGenerateContent, model.id, kind)
                }
            }
            ProviderKind.OpenAI -> {
                val official = OpenAIService.usesOfficialOpenAIApi(provider.baseUrlText)
                if (!official) return Route(chatCompletions(kind), model)
                if (!catalogReady(kind)) return null
                when (openAIOfficialTransport(official, MetadataClient.resolveCatalogModel(model.id, kind)?.transport)) {
                    TransportKind.OpenAIResponses ->
                        catalogRoute(AttachmentTransportProfile.OpenAIResponses, model.id, kind)
                    else -> Route(chatCompletions(kind), model)
                }
            }
            ProviderKind.MiniMax -> {
                if (!catalogReady(kind)) return null
                if (MiniMaxService.routesWebThroughAnthropic(model.id, webSearchEnabled, reasoningMode)) {
                    catalogRoute(AttachmentTransportProfile.MiniMaxAnthropicMessages, model.id, kind)
                } else {
                    openAICompatibleRoute(kind, model)
                }
            }
            // With web search on, the tool loop runs, and its leg request is always Chat Completions.
            ProviderKind.Moonshot ->
                if (webSearchEnabled) Route(chatCompletions(kind), model) else openAICompatibleRoute(kind, model)
            else -> openAICompatibleRoute(kind, model)
        }
    }

    private fun openAICompatibleRoute(kind: ProviderKind, model: AIModel): Route? {
        if (!catalogReady(kind)) return null
        val catalogTransport = MetadataClient.resolveCatalogModel(model.id, kind)?.transport
        return when (openAICompatibleTransport(subscriptionTransport = null, catalogTransport = catalogTransport)) {
            TransportKind.OpenAIResponses -> catalogRoute(AttachmentTransportProfile.OpenAIResponses, model.id, kind)
            else -> Route(chatCompletions(kind), model)
        }
    }

    /** A route with native file blocks: the builder works attachments out from the catalog entry of [catalogKind], and without the catalog nothing can be decided. */
    private fun catalogRoute(
        transport: AttachmentTransportProfile,
        modelId: String,
        catalogKind: ProviderKind,
    ): Route? {
        if (!catalogReady(catalogKind)) return null
        return Route(transport, MetadataClient.resolveAIModelForRouter(modelId, catalogKind))
    }

    /** "Cannot resolve" only means the same at send time once the catalog is really in hand (or the snapshot really has no entry for this provider). */
    private fun catalogReady(kind: ProviderKind): Boolean = when (MetadataClient.catalogLoadState(kind)) {
        MetadataClient.CatalogLoadState.Loaded, MetadataClient.CatalogLoadState.Absent -> true
        MetadataClient.CatalogLoadState.Unavailable, MetadataClient.CatalogLoadState.Pending -> false
    }
}
