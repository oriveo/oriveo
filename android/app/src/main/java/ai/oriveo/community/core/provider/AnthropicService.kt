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
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.applyProfileMergeParams
import ai.oriveo.community.core.provider.transport.parseJsonObjectOrNull
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/**
 * Anthropic Service - talks to the Messages API.
 *
 * Transport wiring:
 *   - the anthropic_messages strategy comes from [TransportRegistry] (the default)
 *   - baseUrl and endpoints come from
 *     [ai.oriveo.community.core.provider.transport.EndpointResolver] (indirectly via
 *     [MetadataClient]), with the hard-coded fallback kept
 *   - during streaming, strategy.parseCitations picks `web_search_tool_result` blocks out
 *     and emits [StreamEvent.Citations], which accumulate into [ChatMessage.citations]
 *   - the mergeParams of profile.webSearch are injected by [applyProfileMergeParams]
 */
class AnthropicService(
    private val client: HttpClient,
    private val json: Json,
    private val transportRegistry: TransportRegistry,
) : ProviderService {

    companion object {
        private const val BASE_URL = "https://api.anthropic.com/v1"
        private const val API_VERSION = "2023-06-01"
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
        MetadataClient.ensureInitialized()

        // anthropic_messages strategy plus the matching streamShape
        val strategy = transportRegistry.strategy(TransportKind.AnthropicMessages)
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Anthropic)
        val webProfileName = resolved?.profiles?.webSearch
        val shape = if (webSearchEnabled) {
            ai.oriveo.community.core.provider.transport.StreamShape.fromMetadata(
                MetadataClient.webSearchStreamShape(webProfileName)
            )
        } else null

        val requestBody = buildMessagesBody(
            modelID, messages, stream = true,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
            supportsImageGen = supportsImageGen,
            webSearchEnabled = webSearchEnabled,
            webProfileName = webProfileName,
            resolved = resolved,
        )
        val continuationRecipe = capabilityRuntimeContinuationSelection(
            ProviderKind.Anthropic, modelID, TransportKind.AnthropicMessages.wireValue, webSearchEnabled, reasoningMode,
        )?.takeIf { it.continuationKind == "replay_blocks" }

        val messagesUrl = "${resolveBaseUrl(baseUrl)}/messages"

        // Sent exactly once. A deterministic upstream 400 that names an unsupported parameter is
        // surfaced with that name; nothing is dropped and resent behind the user's back.
        UnsupportedParamRetry.run(
            ProviderKind.Anthropic,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = officialSelfHealIdentity(
                providerKind = ProviderKind.Anthropic,
                modelID = modelID,
                options = requestOptions,
                finalTransport = TransportKind.AnthropicMessages.wireValue,
                finalUrl = messagesUrl,
            ),
        ) { requestBodyAttempt ->
        val statement = client.preparePost(messagesUrl) {
            applyHeaders(apiKey)
            contentType(ContentType.Application.Json)
            setBody(requestBodyAttempt)
        }

        requestOptions.capabilityExecutionCollector?.confirmDispatched()
        statement.execute { response ->
            if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

            var accumulatedText = ""
            var inputTokens = 0
            var outputTokens = 0
            var cacheReadTokens = 0
            var cacheCreation5m = 0
            var cacheCreation1h = 0
            var cacheReadObserved = false
            var cacheWriteObserved = false
            val continuationBlocks = sortedMapOf<Int, JsonObject>()
            val continuationInputJson = mutableMapOf<Int, StringBuilder>()
            val nativeToolParser = NativeToolCallParser(NativeToolProtocol.AnthropicMessages)

            SseParser.parseAnthropicStreamMulti(
                response = response,
                json = json,
                onEvent = { eventType, data ->
                    val events = mutableListOf<StreamEvent>()
                    val eventRoot = runCatching { json.parseToJsonElement(data).jsonObject }.getOrNull()
                    if (eventRoot != null) {
                        nativeToolParser.parse(eventType, eventRoot).takeIf { it.isNotEmpty() }?.let {
                            events += StreamEvent.ToolCallDeltas(it)
                        }
                    }
                    val blockIndex = (eventRoot?.get("index") as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
                    if (continuationRecipe != null) when (eventType) {
                        "content_block_start" -> (eventRoot?.get("content_block") as? JsonObject)?.let { continuationBlocks[blockIndex] = it }
                        "content_block_delta" -> {
                            val delta = eventRoot?.get("delta") as? JsonObject
                            val current = continuationBlocks[blockIndex]
                            if (delta != null && current != null) {
                                if ((delta["type"] as? JsonPrimitive)?.contentOrNull == "input_json_delta") {
                                    (delta["partial_json"] as? JsonPrimitive)?.contentOrNull?.let { piece ->
                                        continuationInputJson.getOrPut(blockIndex, ::StringBuilder).append(piece)
                                    }
                                }
                                val updated = current.toMutableMap()
                                fun append(field: String) {
                                    val piece = (delta[field] as? JsonPrimitive)?.contentOrNull ?: return
                                    val before = (updated[field] as? JsonPrimitive)?.contentOrNull.orEmpty()
                                    updated[field] = JsonPrimitive(before + piece)
                                }
                                append("text"); append("thinking"); append("signature")
                                continuationBlocks[blockIndex] = JsonObject(updated)
                            }
                        }
                    }
                    // Citation parsing: any content_block_* event may carry a
                    // web_search_tool_result block. The strategy decodes inside runCatching
                    // and returns empty when the shape does not match.
                    if (eventType.startsWith("content_block")) {
                        val cits = strategy.parseCitations(data, shape)
                        if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)
                    }
                    when (eventType) {
                        "message_start" -> {
                            val usage = json.decodeFromString<MessageStartEvent>(data).message?.usage
                            inputTokens = usage?.input_tokens ?: 0
                            cacheReadTokens = usage?.cache_read_input_tokens ?: 0
                            cacheReadObserved = usage?.cache_read_input_tokens != null
                            // Prefer the nested object; older responses fall back to the flat
                            // cache_creation_input_tokens, which counts as 5m.
                            cacheCreation5m = usage?.cache_creation?.ephemeral_5m_input_tokens
                                ?: usage?.cache_creation_input_tokens
                                ?: 0
                            cacheCreation1h = usage?.cache_creation?.ephemeral_1h_input_tokens ?: 0
                            cacheWriteObserved = usage?.cache_creation_input_tokens != null
                                || usage?.cache_creation?.ephemeral_5m_input_tokens != null
                                || usage?.cache_creation?.ephemeral_1h_input_tokens != null
                        }
                        "content_block_delta" -> {
                            // Anthropic content_block_delta distinguishes:
                            //  - type=text_delta -> a body token (appended to accumulatedText plus a Delta event)
                            //  - type=thinking_delta -> a reasoning token (emits a Reasoning event only, never accumulatedText)
                            val delta = json.decodeFromString<ContentDeltaEvent>(data).delta
                            when (delta?.type) {
                                "text_delta" -> {
                                    val text = delta.text
                                    if (!text.isNullOrEmpty()) {
                                        accumulatedText += text
                                        events += StreamEvent.Delta(text)
                                    }
                                }
                                "thinking_delta" -> {
                                    val thinking = delta.thinking
                                    if (!thinking.isNullOrEmpty()) {
                                        events += StreamEvent.Reasoning(thinking)
                                    }
                                }
                                else -> Unit
                            }
                        }
                        "message_delta" -> {
                            val deltaUsage = json.decodeFromString<MessageDeltaEvent>(data).usage
                            outputTokens = deltaUsage?.output_tokens ?: outputTokens
                            // Fallback: a few responses pass the cache fields through on message_delta.
                            deltaUsage?.cache_read_input_tokens?.let {
                                cacheReadTokens = it
                                cacheReadObserved = true
                            }
                            deltaUsage?.cache_creation_input_tokens?.let {
                                cacheCreation5m = it
                                cacheWriteObserved = true
                            }
                            deltaUsage?.cache_creation?.ephemeral_5m_input_tokens?.let {
                                cacheCreation5m = it
                                cacheWriteObserved = true
                            }
                            deltaUsage?.cache_creation?.ephemeral_1h_input_tokens?.let {
                                cacheCreation1h = it
                                cacheWriteObserved = true
                            }
                        }
                    }
                    events
                },
                onDone = {
                    val breakdown = ai.oriveo.community.core.provider.UsageBreakdown(
                        promptTokens = inputTokens,  // Anthropic input_tokens is already the non-cached part
                        cachedInputTokens = cacheReadTokens,
                        cacheCreation5mTokens = cacheCreation5m,
                        cacheCreation1hTokens = cacheCreation1h,
                        completionTokens = outputTokens,
                        reasoningTokens = 0,  // thinking tokens are already counted in output_tokens
                        cacheReadObserved = cacheReadObserved,
                        cacheWriteObserved = cacheWriteObserved,
                    )
                    val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Anthropic)
                    val (cost, source) = ai.oriveo.community.core.provider.CostCalculator.calcCost(breakdown, resolved)
                    StreamEvent.Done(
                        ProviderChatResult(
                            text = accumulatedText.trim(),
                            // The UI treats promptTokens as "total input", so keep the sum
                            // of input + cache_read + cache_create here.
                            promptTokens = inputTokens + cacheReadTokens + cacheCreation5m + cacheCreation1h,
                            completionTokens = outputTokens,
                            estimatedCost = cost,
                            cachedInputTokens = breakdown.reportedCachedInputTokens,
                            cacheCreation5mTokens = breakdown.reportedCacheCreation5mTokens,
                            cacheCreation1hTokens = breakdown.reportedCacheCreation1hTokens,
                            costSource = source.name,
                        )
                    )
                },
            ).collect { event ->
                if (event is StreamEvent.Done && continuationRecipe != null && continuationBlocks.isNotEmpty()) {
                    val completedBlocks = continuationBlocks.map { (index, block) ->
                        val input = continuationInputJson[index]?.toString()?.takeIf { it.isNotBlank() }
                            ?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
                        if (input == null) block else JsonObject(block.toMutableMap().apply { put("input", input) })
                    }
                    emit(StreamEvent.RecipeContinuation(
                        "replay_blocks",
                        continuationRecipe.continuationVariant,
                        JsonObject(mapOf("blocks" to JsonArray(completedBlocks))),
                    ))
                }
                emit(event)
            }
        }
        }
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
        MetadataClient.ensureInitialized()
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Anthropic)
        val body = buildMessagesBody(
            modelID, messages, false, reasoningMode, supportsImageGen, requestOptions, webSearchEnabled,
            resolved?.profiles?.webSearch, resolved,
        )
        val response = client.post("${resolveBaseUrl(baseUrl)}/messages") {
            applyHeaders(apiKey); contentType(ContentType.Application.Json); setBody(body)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val root = json.parseToJsonElement(response.bodyAsText()).jsonObject
        val text = (root["content"] as? JsonArray).orEmpty().mapNotNull {
            ((it as? JsonObject)?.get("text") as? JsonPrimitive)?.contentOrNull
        }.joinToString("").trim()
        if (text.isEmpty()) throw ProviderServiceError.EmptyResponse
        val usage = root["usage"] as? JsonObject
        return StreamEvent.Done(ProviderChatResult(
            text = text,
            promptTokens = (usage?.get("input_tokens") as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0,
            completionTokens = (usage?.get("output_tokens") as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0,
        ))
    }

    /**
     * Resolves the endpoint base URL.
     *
     * User configuration wins, then metadata.providers.anthropic.transport.baseUrl, then the
     * hard-coded fallback. This service exposes no user baseUrl entry point (it targets
     * Anthropic directly), so in practice it falls through to the catalog value.
     */
    private fun resolveBaseUrl(custom: String?): String {
        if (!custom.isNullOrBlank()) return custom.trimEnd('/')
        val transport = MetadataClient.providerTransport(ProviderKind.Anthropic)
        val base = transport?.baseUrl?.takeIf { it.isNotBlank() } ?: "https://api.anthropic.com"
        // The catalog's endpoints.chat is usually "/v1/messages" while this service joins
        // the endpoint itself, so baseUrl + "/v1" keeps the existing joining behaviour.
        val trimmed = base.trimEnd('/')
        // If baseUrl already ends in https://api.anthropic.com/v1, return it as is;
        // otherwise append /v1.
        return if (trimmed.endsWith("/v1")) trimmed else "$trimmed/v1"
    }

    private fun io.ktor.client.request.HttpRequestBuilder.applyHeaders(apiKey: String) {
        header("x-api-key", apiKey)
        header("anthropic-version", API_VERSION)
        header("Accept", "application/json")
    }

    /**
     * Generation parameter injection is funnelled through the outermost layer: an explicit
     * max_output_tokens from the panel has to override the max_tokens written below from the
     * catalog's maxOutputTokens (or the 8192 fallback), and stop has to land as
     * stop_sequences according to profile.wire.
     */
    private fun buildMessagesBody(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        supportsImageGen: Boolean,
        requestOptions: ChatRequestOptions,
        webSearchEnabled: Boolean,
        webProfileName: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): String {
        val projection = officialRequestCapabilityProjection(
            ProviderKind.Anthropic, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.AnthropicMessages.wireValue,
        )
        val generated = GenerationParameterResolver.apply(buildMessagesBodyBase(
            modelID = modelID,
            messages = messages,
            stream = stream,
            reasoningMode = reasoningMode,
            supportsImageGen = supportsImageGen,
            requestOptions = requestOptions,
            webSearchEnabled = webSearchEnabled,
            webProfileName = webProfileName,
            resolved = resolved,
            capabilityProjection = projection,
        ),
        requestOptions,
        resolved,
        projection)
        return applyCapabilityRuntimeCustomFragment(
            generated, ProviderKind.Anthropic, modelID, TransportKind.AnthropicMessages.wireValue, requestOptions,
        )
    }

    private fun buildMessagesBodyBase(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        supportsImageGen: Boolean,
        requestOptions: ChatRequestOptions,
        webSearchEnabled: Boolean,
        webProfileName: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): String {
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        // Resolve the model for AttachmentRouter, which enables cache_control and native PDF.
        val activeModel = MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.Anthropic)
        // Build the message list, attachments included, through MessageBuilder.
        val msgs = MessageBuilder.buildAnthropicMessages(messagesForCapabilityProjection(messages, capabilityProjection), activeModel)

        val extras = mutableListOf<String>()

        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { extras.add(it) }
        }
        MessageBuilder.anthropicSystemJson(options.systemPrompt)?.let { extras.add(it) }

        val extrasStr = if (extras.isNotEmpty()) "," + extras.joinToString(",") else ""
        val maxTokens = (if (capabilityProjection.permitsOutbound("generation_parameter/max_tokens") ||
            capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens")) {
            MessageBuilder.maxTokensJson(options.maxTokens, key = "max_tokens")
        } else null)
            ?: resolved?.maxOutputTokens?.let { """"max_tokens":$it""" }
            ?: """"max_tokens":8192"""
        var baseJson =
            """{"model":"$modelID",$maxTokens,"stream":$stream,"cache_control":{"type":"ephemeral"},"messages":[$msgs]$extrasStr}"""
        val runtime = applyCapabilityRuntimeRecipes(
            bodyJson = baseJson,
            providerKind = ProviderKind.Anthropic,
            modelID = modelID,
            finalTransport = TransportKind.AnthropicMessages.wireValue,
            webRequested = webSearchEnabled,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
        )
        baseJson = runtime.body
        if (!runtime.authoritativeRuntime) {
            baseJson = mergeParamsIntoBody(baseJson, reasoningMergeParams(resolved, reasoningMode).takeIf { reasoningMode == ReasoningMode.Automatic || capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoningMode(resolved, reasoningMode).rawValue}") })
        }

        if (runtime.authoritativeRuntime || !webSearchEnabled || !capabilityProjection.permitsOutbound("web_search") || webProfileName.isNullOrBlank()) return baseJson
        // Profile mergeParams injection: take the current web profile's mergeParams from
        // the catalog and deep-merge them into the body.
        val mergeParams = MetadataClient.webSearchMergeParams(webProfileName) ?: return baseJson
        val baseObj = parseJsonObjectOrNull(baseJson) ?: return baseJson
        val merged = applyProfileMergeParams(
            baseBody = baseObj,
            profileName = webProfileName,
            mergeParams = mergeParams,
        )
        return merged.toString()
    }

    // --- API Types ---

    @Serializable private data class MessageStartEvent(val message: MessageStart? = null)
    @Serializable private data class MessageStart(val usage: AnthropicMessageUsage? = null)

    /**
     * The usage object on Anthropic's `message_start`:
     *   - `input_tokens` excludes cache (it is the part after the last breakpoint)
     *   - `cache_creation` is a nested object splitting 5m from 1h; older responses keep
     *     the flat `cache_creation_input_tokens` instead
     */
    @Serializable
    private data class AnthropicMessageUsage(
        val input_tokens: Int = 0,
        val cache_read_input_tokens: Int? = null,
        val cache_creation_input_tokens: Int? = null,
        val cache_creation: AnthropicCacheCreation? = null,
    )

    @Serializable
    private data class AnthropicCacheCreation(
        val ephemeral_5m_input_tokens: Int? = null,
        val ephemeral_1h_input_tokens: Int? = null,
    )

    @Serializable private data class ContentDeltaEvent(val delta: AnyDelta? = null)
    /**
     * The polymorphic delta of Anthropic content_block_delta:
     *  - type=text_delta: [text] carries a body token
     *  - type=thinking_delta: [thinking] carries an extended thinking token
     *  - anything else (signature_delta and friends): ignored outright
     */
    @Serializable private data class AnyDelta(
        val type: String? = null,
        val text: String? = null,
        val thinking: String? = null,
    )
    @Serializable private data class MessageDeltaEvent(val usage: OutputUsage? = null)
    /**
     * Only output_tokens appears on the `message_delta` event; the cache fields live on
     * message_start. cache_read_input_tokens is still accepted here as a fallback because
     * a few Anthropic responses have passed it through on the delta.
     */
    @Serializable
    private data class OutputUsage(
        val output_tokens: Int = 0,
        val cache_read_input_tokens: Int? = null,
        val cache_creation_input_tokens: Int? = null,
        val cache_creation: AnthropicCacheCreation? = null,
    )
}
