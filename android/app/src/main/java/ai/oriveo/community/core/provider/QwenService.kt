package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.provider.transport.ProviderTransportDefinition
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.TransportEndpoints
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.parseJsonObjectOrNull
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.client.statement.readRawBytes
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.Base64
import java.util.UUID

/**
 * Qwen Service - chat goes through the OpenAI-compatible endpoint
 * `/compatible-mode/v1/chat/completions`.
 *
 * Why not the native DashScope generation endpoint: the newer qwen3.x models (3.5/3.6/3.7)
 * exist only on the compatible endpoint, and the native one answers them with a url error
 * (HTTP 200 plus an in-stream event:error, which gets swallowed silently and surfaces as an
 * empty response).
 * The price paid: the compatible protocol does not return structured
 * `output.search_info.search_results[]` citations - that is an upstream limitation, they
 * exist only on the native endpoint - but enable_search still puts the model online and
 * folds the search results into the answer, and an answer that works beats citation chips.
 *
 * Key points:
 *   - request body: standard OpenAI `{model, messages, stream, stream_options, ...}`
 *   - streaming: `stream:true` triggers SSE
 *     (`data: {choices[].delta.content/reasoning_content}`), so the native DashScope
 *     `X-DashScope-SSE` / `Accept: text/event-stream` headers are not needed
 *   - reasoning: `enable_thinking + thinking_budget`, read as top-level extension
 *     parameters on the compatible endpoint
 *   - web search: `enable_search + search_options` at the top level, not nested under the
 *     native `parameters`
 *   - in-stream errors: both `{"error":{message}}` and a top-level `{"code","message"}`
 *     are recognized, and the real reason is passed through
 *
 * Image generation still goes to the native DashScope multimodal endpoint, kept decoupled
 * from chat; see sendImageGeneration / resolveImageUrl.
 */
class QwenService(
    private val client: HttpClient,
    private val json: Json,
    private val transportRegistry: TransportRegistry,
) : ProviderService {

    companion object {
        // Native DashScope chat endpoint (the international site by default) - kept as the
        // EndpointResolver fallback
        private const val DEFAULT_BASE_URL = "https://dashscope-intl.aliyuncs.com"
        private const val DEFAULT_CHAT_PATH = "/api/v1/services/aigc/text-generation/generation"
        // Multimodal image generation endpoint
        private const val DEFAULT_IMAGE_PATH = "/api/v1/services/aigc/multimodal-generation/generation"
    }

    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        MetadataClient.ensureInitialized()
        // The model list comes from the catalog, so /models is never queried locally.
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
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Qwen)
        // The imageGen profile route (dashscope_multimodal) is the only authority for image
        // dispatch; nothing is inferred from the transport.
        if (supportsImageGen &&
            MetadataClient.imageGenRoute(resolved?.profiles?.imageGen) == "dashscope_multimodal"
        ) {
            // Image generation takes the non-streaming branch.
            val done = sendImageGeneration(apiKey, modelID, messages, baseUrl, resolved)
            emit(done)
            return@flow
        }

        val webProfileName = resolved?.profiles?.webSearch

        val requestBody = buildCompatibleChatBody(
            modelID = modelID,
            messages = messages,
            stream = true,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            webProfileName = webProfileName,
            resolved = resolved,
            requestOptions = requestOptions,
        )

        val url = resolveChatUrl(baseUrl)
        UnsupportedParamRetry.run(
            ProviderKind.Qwen,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = officialSelfHealIdentity(
                providerKind = ProviderKind.Qwen,
                modelID = modelID,
                options = requestOptions,
                finalTransport = TransportKind.OpenAIChat.wireValue,
                finalUrl = url,
            ),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(url) {
                header("Authorization", "Bearer $apiKey")
                header("Accept", "application/json")
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

                var accumulatedText = ""
                var accumulatedReasoning = ""
                var lastUsageJson: JsonObject? = null

                // The DashScope compatible endpoint speaks standard OpenAI SSE
                // (`data: {choices[].delta.content}` plus an optional `[DONE]`).
                // The compatible protocol returns no structured citations, but enable_search
                // still puts the model online.
                SseParser.parseOpenAICompatibleMulti(
                    response = response,
                    json = json,
                    onChunk = { payload ->
                        val events = mutableListOf<StreamEvent>()
                        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
                        if (root != null) {
                            // OpenAI-compatible: usage sits at the top level, and mid-chunk it
                            // can be JsonNull, hence the as? filter.
                            (root["usage"] as? JsonObject)?.let { lastUsageJson = it }
                        }
                        val chunk = runCatching { json.decodeFromString<QwenCompatChunk>(payload) }.getOrNull()
                        val delta = chunk?.choices?.firstOrNull()?.delta
                        // Reasoning models emit reasoning_content first while content is
                        // still null; separate branches keep one from short-circuiting the other.
                        val reasoning = delta?.reasoning_content ?: delta?.reasoning
                        if (!reasoning.isNullOrEmpty()) {
                            accumulatedReasoning += reasoning
                            events += StreamEvent.Reasoning(reasoning)
                        }
                        val content = delta?.content
                        if (!content.isNullOrEmpty()) {
                            accumulatedText += content
                            events += StreamEvent.Delta(content)
                        }
                        events
                    },
                    onDone = {
                        val breakdown = parseUsage(lastUsageJson)
                        val (cost, source) = CostCalculator.calcCost(breakdown, resolved)
                        StreamEvent.Done(
                            ProviderChatResult(
                                text = accumulatedText.trim(),
                                promptTokens = breakdown.promptTokens + breakdown.cachedInputTokens,
                                completionTokens = breakdown.completionTokens,
                                estimatedCost = cost,
                                reasoningText = accumulatedReasoning.trim().takeIf { it.isNotEmpty() },
                                cachedInputTokens = breakdown.reportedCachedInputTokens,
                                costSource = source.name,
                            )
                        )
                    },
                ).collect { emit(it) }
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
        // Same shape as sendMessageStream: make sure the catalog is ready first, otherwise
        // route reads empty and image dispatch degrades into an ordinary chat.
        MetadataClient.ensureInitialized()
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Qwen)
        // The imageGen profile route (dashscope_multimodal) is the only authority for image
        // dispatch. ChatRepository takes exactly this non-streaming path when supportsImageGen
        // is set and the provider is not a relay, so getting the check wrong would send an
        // image request to the compatible chat endpoint.
        if (supportsImageGen &&
            MetadataClient.imageGenRoute(resolved?.profiles?.imageGen) == "dashscope_multimodal"
        ) {
            return sendImageGeneration(apiKey, modelID, messages, baseUrl, resolved)
        }
        val body = buildCompatibleChatBody(
            modelID, messages, stream = false, reasoningMode, webSearchEnabled,
            resolved?.profiles?.webSearch, resolved, requestOptions,
        )
        val response = client.post(resolveChatUrl(baseUrl)) {
            header("Authorization", "Bearer $apiKey")
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        return parseOpenAIChatDone(json, response.bodyAsText())
    }

    /**
     * Builds the OpenAI-compatible request body for the DashScope compatible endpoint;
     * generation parameter injection is funnelled through the outermost layer.
     *
     * Visible to this module rather than private so that request-body structure tests can
     * call it directly: reaching it by reflection would turn a signature drift into a runtime
     * NoSuchMethodException, whereas a direct call fails at compile time.
     */
    internal fun buildCompatibleChatBody(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        webProfileName: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
        requestOptions: ChatRequestOptions,
    ): String {
        val capabilityProjection = officialRequestCapabilityProjection(
            ProviderKind.Qwen, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.OpenAIChat.wireValue,
        )
        val generated = GenerationParameterResolver.apply(buildCompatibleChatBodyBase(
            modelID = modelID,
            messages = messages,
            stream = stream,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            webProfileName = webProfileName,
            resolved = resolved,
            requestOptions = requestOptions,
            capabilityProjection = capabilityProjection,
        ),
        requestOptions,
        resolved,
        capabilityProjection)
        return applyCapabilityRuntimeCustomFragment(
            generated, ProviderKind.Qwen, modelID, TransportKind.OpenAIChat.wireValue, requestOptions,
        )
    }

    private fun buildCompatibleChatBodyBase(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        webProfileName: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
        requestOptions: ChatRequestOptions,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): String {
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        // Reuse the same message construction as the other OpenAI-compatible providers,
        // attachment injection and image_url parts included.
        val msgs = MessageBuilder.buildOpenAIMessages(messagesForCapabilityProjection(messages, capabilityProjection), ProviderKind.Qwen, options.systemPrompt)

        val extras = mutableListOf<String>()
        if (stream) extras.add(""""stream_options":{"include_usage":true}""")
        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { extras.add(it) }
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/max_tokens") || capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens")) MessageBuilder.maxTokensJson(options.maxTokens)?.let { extras.add(it) }

        val extrasStr = if (extras.isEmpty()) "" else "," + extras.joinToString(",")
        var baseJson = """{"model":"$modelID","stream":$stream,"messages":[$msgs]$extrasStr}"""
        val runtime = applyCapabilityRuntimeRecipes(
            baseJson, ProviderKind.Qwen, modelID, TransportKind.OpenAIChat.wireValue,
            webSearchEnabled, reasoningMode, requestOptions,
        )
        baseJson = runtime.body
        if (!runtime.authoritativeRuntime) baseJson = mergeParamsIntoBody(baseJson, reasoningMergeParams(resolved, reasoningMode).takeIf { reasoningMode == ReasoningMode.Automatic || capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoningMode(resolved, reasoningMode).rawValue}") })

        if (runtime.authoritativeRuntime || !webSearchEnabled || !capabilityProjection.permitsOutbound("web_search")) return baseJson

        // Web search: the DashScope compatible endpoint reads enable_search / search_options
        // as TOP-LEVEL extension parameters, not nested under `parameters` the way the native
        // endpoint does. The compatible protocol returns no structured citations, but the
        // search still runs and improves the answer.
        val baseObj = parseJsonObjectOrNull(baseJson) ?: return baseJson
        val rawMerge = webSearchMergeParams(webProfileName) ?: return baseJson
        val merged = buildJsonObject {
            baseObj.forEach { (k, v) -> put(k, v) }
            rawMerge.forEach { (k, v) ->
                // If the catalog still carries the native {parameters:{...}} nesting, flatten
                // it to the top level; the compatible endpoint does not recognize a parameters
                // field, so enable_search would fail silently.
                if (k == "parameters" && v is JsonObject) {
                    v.forEach { (pk, pv) -> put(pk, pv) }
                } else {
                    put(k, v)
                }
            }
        }
        return merged.toString()
    }

    /** OpenAI-compatible usage parsing (prompt/completion, plus two fallbacks for cached and reasoning). */
    private fun parseUsage(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val prompt = usage["prompt_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val completion = usage["completion_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val cached = (usage["prompt_tokens_details"] as? JsonObject)
            ?.get("cached_tokens")?.jsonPrimitive?.intOrNull
            ?: usage["cached_tokens"]?.jsonPrimitive?.intOrNull
            ?: 0
        val reasoning = (usage["completion_tokens_details"] as? JsonObject)
            ?.get("reasoning_tokens")?.jsonPrimitive?.intOrNull ?: 0
        return UsageBreakdown(
            promptTokens = (prompt - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = completion,
            reasoningTokens = reasoning,
            cacheReadObserved = (usage["prompt_tokens_details"] as? JsonObject)
                ?.get("cached_tokens")?.jsonPrimitive?.intOrNull != null
                || usage["cached_tokens"]?.jsonPrimitive?.intOrNull != null,
        )
    }

    /**
     * Resolves the chat endpoint, always onto the OpenAI-compatible one.
     * On an official DashScope host: `{origin}/compatible-mode/v1/chat/completions`;
     * on a custom proxy (any non-DashScope host): `{base}/chat/completions`.
     * The native chat path from the catalog is ignored on purpose: the newer qwen3.x models
     * exist only on the compatible endpoint, and forcing it means output still appears even
     * when the catalog lags behind or a stale cache still carries the native path.
     */
    private fun resolveChatUrl(custom: String?): String {
        val userBase = custom?.trim()?.takeIf { it.isNotBlank() }
        val normalizedUserBase = userBase?.let { normalizeUserBaseUrl(it) }
        return EndpointResolver.resolveEndpoint(
            provider = ai.oriveo.community.core.model.Provider(
                id = "runtime-qwen",
                kind = ProviderKind.Qwen,
                baseUrlText = normalizedUserBase,
            ),
            kind = EndpointResolver.EndpointKind.CHAT,
            metadata = providerTransportDefinition(),
        )
    }

    private fun normalizeUserBaseUrl(base: String): String {
        var trimmed = base.trim().trimEnd('/')
        if (!trimmed.startsWith("http")) trimmed = "https://$trimmed"
        if (trimmed.endsWith("/chat/completions")) return trimmed
        val nativeIdx = trimmed.indexOf(DEFAULT_CHAT_PATH)
        if (nativeIdx >= 0) trimmed = trimmed.substring(0, nativeIdx)
        return trimmed.removeSuffix("/compatible-mode/v1").trimEnd('/')
    }

    private fun resolveImageUrl(custom: String?): String {
        val userBase = custom?.trim()?.takeIf { it.isNotBlank() }
        if (!userBase.isNullOrBlank()) {
            val trimmed = userBase.trimEnd('/')
            // The user may have pasted the full chat path, so swap it for the image path.
            if (trimmed.endsWith(DEFAULT_CHAT_PATH)) {
                return trimmed.removeSuffix(DEFAULT_CHAT_PATH) + DEFAULT_IMAGE_PATH
            }
            // Handle a baseURL left over from OpenAI-compatible mode: strip
            // /compatible-mode/v1 before joining the native image path.
            val stripCompat = trimmed.removeSuffix("/compatible-mode/v1")
            return "$stripCompat$DEFAULT_IMAGE_PATH"
        }
        val transport = MetadataClient.providerTransport(ProviderKind.Qwen)
        val metadata = transport?.let {
            ProviderTransportDefinition(
                baseUrl = it.baseUrl,
                endpoints = TransportEndpoints(
                    chat = it.endpoints.chat,
                    responses = it.endpoints.responses,
                    images = it.endpoints.images,
                    embeddings = it.endpoints.embeddings,
                    files = it.endpoints.files,
                ),
            )
        }
        return EndpointResolver.resolveEndpoint(
            provider = ai.oriveo.community.core.model.Provider(
                id = "runtime-qwen",
                kind = ProviderKind.Qwen,
            ),
            kind = EndpointResolver.EndpointKind.IMAGES,
            metadata = metadata,
        )
    }

    private fun providerTransportDefinition(): ProviderTransportDefinition? {
        val transport = MetadataClient.providerTransport(ProviderKind.Qwen) ?: return null
        return ProviderTransportDefinition(
            baseUrl = transport.baseUrl,
            endpoints = TransportEndpoints(
                chat = transport.endpoints.chat,
                responses = transport.endpoints.responses,
                images = transport.endpoints.images,
                embeddings = transport.endpoints.embeddings,
                files = transport.endpoints.files,
            ),
        )
    }

    /** Image generation goes to the DashScope multimodal endpoint, which answers in one shot. */
    private suspend fun sendImageGeneration(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): StreamEvent.Done {
        val prompt = messages.lastOrNull { it.role == ChatRole.User }
            ?.text?.takeIf { it.isNotBlank() }
            ?: throw ProviderServiceError.InvalidConfiguration("Image generation requires a text prompt.")

        val imageGenUrl = resolveImageUrl(baseUrl)
        val escapedPrompt = json.encodeToString(kotlinx.serialization.serializer<String>(), prompt)
        // The fields inside the parameters block (size / n / prompt_extend) come from the
        // catalog's requestDefaults so they can be corrected without a client release,
        // instead of being hard-coded here.
        val parametersJson = (MetadataClient.imageGenRequestDefaults(resolved?.profiles?.imageGen)
            ?: buildJsonObject {}).toString()
        val requestBody =
            """{"model":"$modelID","input":{"messages":[{"role":"user","content":[{"text":$escapedPrompt}]}]},"parameters":$parametersJson}"""

        val response = client.post(imageGenUrl) {
            header("Authorization", "Bearer $apiKey")
            header("X-DashScope-Async", "disable")
            contentType(ContentType.Application.Json)
            setBody(requestBody)
        }
        if (!response.status.isSuccess()) {
            throw ProviderServiceError.Upstream(
                statusCode = response.status.value,
                detail = "Qwen image generation failed",
            )
        }

        val body = response.bodyAsText()
        val jsonObj = json.parseToJsonElement(body).jsonObject
        val imageUrl = jsonObj["output"]?.jsonObject
            ?.get("choices")?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("message")?.jsonObject
            ?.get("content")?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("image")?.jsonPrimitive?.content

        if (imageUrl.isNullOrBlank()) {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "No image generated in Qwen response",
            )
        }

        val attachments = try {
            val imageResponse = client.get(imageUrl)
            if (!imageResponse.status.isSuccess()) {
                throw ProviderServiceError.Upstream(
                    statusCode = imageResponse.status.value,
                    detail = "Qwen generated image download failed",
                )
            }
            val imageBytes = imageResponse.readRawBytes()
            val base64 = Base64.getEncoder().encodeToString(imageBytes)
            listOf(
                Attachment(
                    id = UUID.randomUUID().toString(),
                    kind = AttachmentKind.Image,
                    fileName = "qwen-image.png",
                    mimeType = "image/png",
                    base64Data = base64,
                ),
            )
        } catch (_: Exception) {
            listOf(
                Attachment(
                    id = UUID.randomUUID().toString(),
                    kind = AttachmentKind.Image,
                    fileName = "qwen-image.png",
                    mimeType = "image/png",
                    base64Data = imageUrl,
                ),
            )
        }

        return StreamEvent.Done(
            ProviderChatResult(
                text = "",
                attachments = attachments,
            ),
        )
    }

    // --- OpenAI-compatible streaming chunk types ---

    @Serializable
    private data class QwenCompatChunk(val choices: List<QwenCompatChoice>? = null)

    @Serializable
    private data class QwenCompatChoice(val delta: QwenCompatDelta? = null)

    @Serializable
    private data class QwenCompatDelta(
        val content: String? = null,
        val reasoning_content: String? = null,
        // Some deployments put reasoning on delta.reasoning without the _content suffix,
        // so both spellings are checked.
        val reasoning: String? = null,
    )
}
