package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.StreamShape
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.applyProfileMergeParams
import ai.oriveo.community.core.provider.transport.parseJsonObjectOrNull
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.preparePost
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant

/**
 * The OpenRouter provider implementation.
 *
 * It covers model sync with expiry filtering, recommendations and cost estimation; streaming
 * messages with attachments and image generation; mapping a reasoning mode onto
 * `reasoning.effort`; and the attachment formats (image_url / file / inline text).
 *
 * Capability wiring:
 *   - [TransportRegistry] supplies the openai_chat strategy. Every OpenRouter model goes through
 *     Chat Completions.
 *   - While streaming, `strategy.parseCitations` uses the `or_web` profile streamShape
 *     (citationsArrayPath="choices.0.message.annotations" / citationUrlField="url_citation.url").
 */
class OpenRouterService(
    private val client: HttpClient,
    private val json: Json,
    private val transportRegistry: TransportRegistry,
) : ProviderService, BalanceQueryable {

    companion object {
        private const val BASE_URL = "https://openrouter.ai/api/v1"
        private const val DEFAULT_ORIGIN = "https://openrouter.ai"
    }

    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        MetadataClient.ensureInitialized()

        return ProviderSyncResult(models = emptyList())
    }

    override suspend fun sendMessage(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        if (apiKey.isBlank() || modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing provider credentials.")
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.OpenRouter)
        val body = buildRequestBody(
            modelID, messages, stream = false, supportsImageGen, reasoningMode, webSearchEnabled,
            resolved?.profiles?.webSearch, resolved, requestOptions,
        )
        val response = client.post("$BASE_URL/chat/completions") {
            applyHeaders(apiKey); contentType(ContentType.Application.Json); setBody(body)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        return parseOpenAIChatDone(json, response.bodyAsText())
    }

    override fun sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing API key.")
        if (modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing model identifier.")

        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.OpenRouter)
        val webProfileName = resolved?.profiles?.webSearch
        val body = buildRequestBody(
            modelID, messages, stream = true,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            webSearchProfileName = webProfileName,
            resolved = resolved,
            requestOptions = requestOptions,
        )

        // openai_chat strategy plus the or_web streamShape, which drives OpenRouter's streaming
        // citation parsing.
        val strategy = transportRegistry.strategy(TransportKind.OpenAIChat)
        val shape = if (webSearchEnabled) {
            StreamShape.fromMetadata(MetadataClient.webSearchStreamShape(webProfileName))
        } else null
        val continuationRecipe = capabilityRuntimeContinuationSelection(
            ProviderKind.OpenRouter, modelID, TransportKind.OpenAIChat.wireValue,
            webSearchEnabled, reasoningMode,
        )?.takeIf { it.continuationKind == "replay_reasoning" }

        val chatUrl = "$BASE_URL/chat/completions"
        UnsupportedParamRetry.run(
            ProviderKind.OpenRouter,
            modelID,
            body,
            requestOptions = requestOptions,
            identity = officialSelfHealIdentity(
                providerKind = ProviderKind.OpenRouter,
                modelID = modelID,
                options = requestOptions,
                finalTransport = TransportKind.OpenAIChat.wireValue,
                finalUrl = chatUrl,
            ),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(chatUrl) {
                applyHeaders(apiKey)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    throw SseParser.mapHttpError(response)
                }

                var accumulatedText = ""
                var accumulatedReasoning = ""
                var lastUsage: Usage? = null
                var lastModel: String? = null
                val continuationAccumulator = continuationRecipe?.responseParserKind?.let {
                    ProviderRecipeExecution.ReasoningAssistantAccumulator(it)
                }

                SseParser.parseOpenAICompatibleMulti(
                    response = response,
                    json = json,
                    onChunk = { payload ->
                        val events = mutableListOf<StreamEvent>()
                        val rawRoot = runCatching {
                            json.parseToJsonElement(payload) as? kotlinx.serialization.json.JsonObject
                        }.getOrNull()
                        val rawDelta = ((rawRoot?.get("choices") as? kotlinx.serialization.json.JsonArray)
                            ?.firstOrNull() as? kotlinx.serialization.json.JsonObject)
                            ?.get("delta") as? kotlinx.serialization.json.JsonObject
                        rawDelta?.let { continuationAccumulator?.ingest(it) }
                        val chunk = json.decodeFromString<StreamChunk>(payload)
                        chunk.model?.let { lastModel = it }
                        chunk.usage?.let { lastUsage = it }

                        // Citation parsing; the strategy already wraps this in runCatching.
                        val cits = runCatching { strategy.parseCitations(payload, shape) }
                            .getOrNull()
                            .orEmpty()
                        if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)

                        val deltaObject = chunk.choices?.firstOrNull()?.delta
                        // Reasoning is looked up under two names (reasoning_content, then
                        // reasoning), the same way OpenAICompatibleService does it. OpenRouter
                        // normalizes the thinking output of every upstream model onto
                        // delta.reasoning, and missing that name is what previously left thinking
                        // invisible.
                        val reasoningDelta = deltaObject?.reasoning_content ?: deltaObject?.reasoning
                        if (!reasoningDelta.isNullOrEmpty()) {
                            accumulatedReasoning += reasoningDelta
                            events += StreamEvent.Reasoning(reasoningDelta)
                        }
                        val delta = deltaObject?.content
                        if (!delta.isNullOrEmpty()) {
                            accumulatedText += delta
                            events += StreamEvent.Delta(delta)
                        }
                        events
                    },
                    onDone = {
                        val usage = lastUsage
                        val cached = usage?.prompt_tokens_details?.cached_tokens ?: 0
                        val cacheWrite = usage?.prompt_tokens_details?.cache_write_tokens ?: 0
                        val breakdown = ai.oriveo.community.core.provider.UsageBreakdown(
                            promptTokens = ((usage?.prompt_tokens ?: 0) - cached - cacheWrite).coerceAtLeast(0),
                            cachedInputTokens = cached,
                            // OpenRouter passes cache writes through for Anthropic models; count
                            // them as 1h, which is OpenRouter's default TTL.
                            cacheCreation1hTokens = cacheWrite,
                            completionTokens = usage?.completion_tokens ?: 0,
                            // OpenRouter returns cost by default, already net of every discount.
                            upstreamCost = usage?.cost,
                            cacheReadObserved = usage?.prompt_tokens_details?.cached_tokens != null,
                            cacheWriteObserved = usage?.prompt_tokens_details?.cache_write_tokens != null,
                        )
                        // There is no local catalog pricing for OpenRouter, since the user is
                        // routing many vendors' models through it. Passing pricing=null makes
                        // CostCalculator report UNKNOWN, but a non-null upstreamCost takes
                        // precedence over that.
                        val (cost, source) = ai.oriveo.community.core.provider.CostCalculator.calcCost(breakdown, null)
                        StreamEvent.Done(
                            ProviderChatResult(
                                text = accumulatedText.trim(),
                                promptTokens = usage?.prompt_tokens ?: 0,
                                completionTokens = usage?.completion_tokens ?: 0,
                                estimatedCost = cost,
                                servedModelID = lastModel,
                                reasoningText = accumulatedReasoning.trim().takeIf { it.isNotEmpty() },
                                cachedInputTokens = breakdown.reportedCachedInputTokens,
                                cacheCreation1hTokens = breakdown.reportedCacheCreation1hTokens,
                                costSource = source.name,
                            )
                        )
                    },
                ).collect { event ->
                    if (event is StreamEvent.Done) {
                        continuationAccumulator?.stateOrNull()?.let { state ->
                            emit(StreamEvent.RecipeContinuation(
                                "replay_reasoning", continuationRecipe?.continuationVariant, state,
                            ))
                        }
                    }
                    emit(event)
                }
            }
        }
    }

    /**
     * Account balance: `GET ${origin}/api/v1/credits`, computed as
     * `data.total_credits - data.total_usage`.
     *
     * The published OpenAPI marks this as requiring a management key, but an ordinary Bearer key
     * was measured to work. On a 401 the caller should hide the card silently, since it is not a
     * problem with the user's key.
     */
    override suspend fun fetchBalance(apiKey: String, baseURL: String?): ProviderBalance {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        val origin = ai.oriveo.community.core.provider.balanceOriginOf(baseURL, DEFAULT_ORIGIN)
        val response = client.get("$origin/api/v1/credits") {
            applyHeaders(apiKey)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val body = response.bodyAsText()
        val parsed = json.decodeFromString<CreditsEnvelope>(body)
        val data = parsed.data ?: throw ProviderServiceError.Upstream(200, "OpenRouter credits payload missing data.")
        val balance = (data.total_credits ?: 0.0) - (data.total_usage ?: 0.0)
        // OpenRouter has no notion of granted credit: total_credits is the cumulative amount
        // topped up and total_usage is the cumulative amount spent. Mapping total_credits to
        // granted and total_usage to topUp, as this once did, inverts the meaning of the
        // "granted" and "topped up" labels in the UI.
        return ProviderBalance(
            currency = "USD",
            total = balance,
            granted = null,
            topUp = data.total_credits,
            totalUsage = data.total_usage,
            fetchedAt = Instant.now(),
        )
    }

    // ── Private helpers ──

    private fun buildRequestBody(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        webSearchProfileName: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
        requestOptions: ChatRequestOptions,
    ): String {
        val capabilityProjection = officialRequestCapabilityProjection(
            ProviderKind.OpenRouter, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.OpenAIChat.wireValue,
        )
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        // Build the message array with MessageBuilder so attachments are included.
        val msgs = MessageBuilder.buildOpenAIMessages(
            messages = messagesForCapabilityProjection(messages, capabilityProjection),
            providerKind = ProviderKind.OpenRouter,
            systemPrompt = options.systemPrompt,
        )

        val extras = mutableListOf<String>()

        // Modalities for image generation.
        if (supportsImageGen) {
            extras.add(""""modalities":["text","image"]""")
        }

        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { extras.add(it) }
        }
        val safeMaxTokens = options.maxTokens ?: resolved?.maxOutputTokens
        if (options.maxTokens == null || capabilityProjection.permitsOutbound("generation_parameter/max_tokens") || capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens")) MessageBuilder.maxTokensJson(safeMaxTokens)?.let { extras.add(it) }

        // stream_options for usage tracking
        if (stream) {
            extras.add(""""stream_options":{"include_usage":true}""")
        }

        val extrasStr = if (extras.isNotEmpty()) "," + extras.joinToString(",") else ""
        var baseJson = """{"model":"$modelID","stream":$stream,"messages":[$msgs]$extrasStr}"""
        val runtime = applyCapabilityRuntimeRecipes(
            bodyJson = baseJson,
            providerKind = ProviderKind.OpenRouter,
            modelID = modelID,
            finalTransport = TransportKind.OpenAIChat.wireValue,
            webRequested = webSearchEnabled,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
        )
        baseJson = runtime.body
        val effectiveReasoning = effectiveReasoningMode(resolved, reasoningMode)
        if (!runtime.authoritativeRuntime) baseJson = mergeParamsIntoBody(baseJson, reasoningMergeParams(resolved, reasoningMode).takeIf { reasoningMode == ReasoningMode.Automatic || capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoning.rawValue}") })
        if (!runtime.authoritativeRuntime && webSearchEnabled && capabilityProjection.permitsOutbound("web_search")) {
            baseJson = injectWebSearchProfile(baseJson, webSearchProfileName)
        }
        // Injecting generation parameters is the last step: explicit values from the panel
        // override the max_tokens and temperature defaults written above from catalog metadata,
        // and OpenRouter-specific parameters such as route_require_parameters are placed into the
        // nested provider.* object according to profile.wire.
        val generated = GenerationParameterResolver.apply(
            baseJson,
            requestOptions,
            resolved,
            capabilityProjection,
        )
        return applyCapabilityRuntimeCustomFragment(
            generated, ProviderKind.OpenRouter, modelID, TransportKind.OpenAIChat.wireValue, requestOptions,
        )
    }

    private fun injectWebSearchProfile(baseJson: String, profileName: String?): String {
        val mergeParams = MetadataClient.webSearchMergeParams(profileName) ?: return baseJson
        val baseObject = parseJsonObjectOrNull(baseJson) ?: return baseJson
        val merged = applyProfileMergeParams(
            baseBody = baseObject,
            profileName = profileName,
            mergeParams = mergeParams,
        )
        return json.encodeToString(kotlinx.serialization.json.JsonObject.serializer(), merged)
    }

    private fun io.ktor.client.request.HttpRequestBuilder.applyHeaders(apiKey: String) {
        header("Accept", "application/json")
        header("Authorization", "Bearer $apiKey")
        header("HTTP-Referer", "https://github.com/oriveo/oriveo")
        header("X-Title", "Oriveo")
    }

    // ── API Response Types ──

    @Serializable
    private data class StreamChunk(
        val choices: List<ChunkChoice>? = null,
        val usage: Usage? = null,
        val model: String? = null,
    )

    @Serializable
    private data class ChunkChoice(
        val delta: ChunkDelta? = null,
    )

    @Serializable
    private data class ChunkDelta(
        val content: String? = null,
        val reasoning_content: String? = null,
        // Groq, Together (gpt-oss) and OpenRouter use `reasoning`, without the _content suffix,
        // so both names are checked.
        val reasoning: String? = null,
    )

    @Serializable
    private data class Usage(
        val prompt_tokens: Int = 0,
        val completion_tokens: Int = 0,
        val total_tokens: Int = 0,
        // OpenRouter attaches cost (in USD) to the response by default. It already accounts for
        // every cache discount, so it can be adopted directly as upstreamCost.
        val cost: Double? = null,
        val prompt_tokens_details: UsagePromptDetails? = null,
    )

    @Serializable
    private data class UsagePromptDetails(
        val cached_tokens: Int? = null,
        // OpenRouter passes cache_write_tokens through for Anthropic models, treated as a 1h write.
        val cache_write_tokens: Int? = null,
    )

    // ── Balance API ──

    @Serializable
    private data class CreditsEnvelope(val data: CreditsData? = null)

    @Serializable
    private data class CreditsData(
        val total_credits: Double? = null,
        val total_usage: Double? = null,
    )
}
