package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.core.provider.LocalEngineRuntimeClient
import ai.oriveo.community.core.provider.LocalPromptPreflight
import ai.oriveo.community.core.provider.NativeToolCallParser
import ai.oriveo.community.core.provider.NativeToolProtocol
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.ProviderValidationStrategy
import ai.oriveo.community.core.provider.CatalogModelBuilder
import ai.oriveo.community.core.provider.RelayErrorContext
import ai.oriveo.community.core.provider.RelayErrorMapper
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.RelayFamilyHeuristics
import ai.oriveo.community.core.provider.RelayModelFamily
import ai.oriveo.community.core.provider.RelayRetryHints
import ai.oriveo.community.core.provider.RelayUpstreamErrorPayload
import ai.oriveo.community.core.provider.SseParser
import ai.oriveo.community.core.provider.UnsupportedParamRetry
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.UsageBreakdown
import ai.oriveo.community.core.provider.escapeJsonString
import ai.oriveo.community.core.provider.isRelayGenerationSuccessResponse
import ai.oriveo.community.core.provider.relay.RelayHeaderBuilder.applyRelayHeaders
import ai.oriveo.community.core.provider.relay.RelayHeaderBuilder.resolveAuthMode
import ai.oriveo.community.core.provider.transport.StreamShape
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.TransportStrategy
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.client.statement.request
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.utils.io.jvm.javaio.toInputStream
import java.nio.charset.StandardCharsets
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Runtime service for relay endpoints.
 *
 * - syncProvider keeps the older `/models` directory sync so the simple path still works
 * - sendMessage/sendMessageStream dispatch to one of four protocols based on
 *   relayRequested.transport
 *
 * Capability handling:
 *   - [TransportRegistry] supplies the strategy for each of the four transports (openai_chat /
 *     openai_responses / anthropic_messages / gemini_generate)
 *   - while streaming, citations are parsed with strategy.parseCitations and emitted as
 *     [StreamEvent.Citations]
 *   - relay models are not in the catalog, so the profile streamShape is looked up through
 *     [MetadataClient.webSearchStreamShape] using the `relayRequested.webSearchProfile` the user
 *     picked in the UI
 *   - `relayRequested.transportKind` and `relayRequested.transport` together decide which strategy
 *     is selected
 */
internal class RelayTransportCoordinator(
    client: HttpClient,
    private val json: Json,
    private val transportRegistry: TransportRegistry,
) : ProviderService,
    RelayOpenAIResponsesTransport.Delegate,
    RelayOpenAIChatTransport.Delegate,
    RelayAnthropicMessagesTransport.Delegate,
    RelayGeminiTransport.Delegate {

    private val client = client.config { install(relayLocalSecurityPlugin()) }
    private val localRuntimeClient = LocalEngineRuntimeClient(this.client, json)

    companion object {
        private val EXCLUDED_PREFIXES = setOf(
            "dall-e",
            "whisper",
            "tts",
            "text-embedding",
            "babbage",
            "davinci",
            "moderation",
            "omni-moderation",
            "codex",
        )

        // The finishReason and promptFeedback.blockReason values Gemini uses to say the content was
        // blocked. STOP, MAX_TOKENS and null are normal terminations and are deliberately absent.
        private val GEMINI_BLOCKED_REASONS = setOf(
            "SAFETY",
            "RECITATION",
            "PROHIBITED_CONTENT",
            "BLOCKLIST",
            "SPII",
        )

        private const val MALFORMED_SUCCESS_RESPONSE_GUIDANCE =
            "The provider returned an error for this request. Please retry or switch models."
        private const val MALFORMED_SCHEMA_RESPONSE_DETAIL =
            "The custom LLM returned JSON that does not match the expected response schema."
    }

    private val openAIResponsesTransport = RelayOpenAIResponsesTransport(this)
    private val openAIChatTransport = RelayOpenAIChatTransport(this)
    private val anthropicMessagesTransport = RelayAnthropicMessagesTransport(this)
    private val geminiTransport = RelayGeminiTransport(this)

    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult = syncProvider(apiKey, preferredModelID, baseUrl, relayRequested = null)

    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
        relayRequested: RelayRequestedConfig?,
    ): ProviderSyncResult {
        // An empty key is a legitimate state in the no-credential mode (authMode == None, which
        // covers local engines and relays that explicitly need no auth), so only relays that do
        // require a credential get the non-empty check. Without this split, refreshing the model
        // directory of a local engine is rejected before the request is ever made.
        if (relayRequested.requiresCredential && !hasStoredCredential(apiKey)) {
            throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        }

        // Any relay that has been persisted must carry its real securityMode and authMode. The
        // historical Bearer plus remote_https placeholder is only used for older callers that
        // genuinely pass no relayRequested at all.
        val requestOptions = ChatRequestOptions(
            relayRequested = relayRequested ?: RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    authMode = RelayAuthMode.Bearer,
                ),
        )
        val upstreamUrl = buildUrl(baseUrl, "/models")
        val response = client.get(upstreamUrl) {
            applyRelayHeaders(
                apiKey = apiKey,
                requestOptions = requestOptions,
                transport = RelayTransport.OpenAIChatCompletions,
            )
        }
        if (!response.status.isSuccess()) {
            throw mapRelayHttpError(
                response = response,
                upstreamUrl = upstreamUrl,
                requestOptions = requestOptions,
                modelID = preferredModelID,
            )
        }

        val parsed = decodeRelaySuccessResponse<ModelsResponse>(response)
        val models = buildModels(parsed.data, preferredModelID)
        if (models.isEmpty()) throw ProviderServiceError.EmptyModelCatalog
        return ProviderSyncResult(models = models)
    }

    /**
     * One-shot image generation through `/images/generations`, used when imageRoute is
     * images_endpoint.
     *
     * Unlike the chat protocols there is no conversation context and no streaming: a single POST
     * returns `data[].b64_json`. Measured against the inline Responses tool it is far faster
     * (21s versus 62s) and the model parameter actually takes effect.
     *
     * Note that `gpt-image-*` does not accept `response_format`, which already defaults to
     * b64_json. Sending it explicitly gets a 400 Unknown parameter back from OpenAI directly and
     * from strict relays.
     */
    suspend fun generateImageViaImagesEndpoint(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        validateChatRequest(apiKey, modelID, requestOptions)
        val prompt = messages.lastOrNull { it.role.name == "User" }?.text?.trim()
        if (prompt.isNullOrBlank()) {
            throw ProviderServiceError.InvalidConfiguration("Image generation requires a text prompt.")
        }

        val relayRequested = requestOptions.relayRequested
        val body = buildJsonObject {
            put("model", modelID)
            put("prompt", prompt)
            relayRequested?.imageCount?.takeIf { it > 0 }?.let { put("n", it) }
            relayRequested?.imageSize?.trim()?.takeIf { it.isNotEmpty() }?.let { put("size", it) }
            relayRequested?.imageQuality?.trim()?.takeIf { it.isNotEmpty() }?.let { put("quality", it) }
            relayRequested?.imageStyle?.trim()?.takeIf { it.isNotEmpty() }?.let { put("style", it) }
            if (!RelayRuntimeSupport.isDedicatedImageModel(modelID)) {
                relayRequested?.imageResponseFormat?.trim()?.takeIf { it.isNotEmpty() }
                    ?.let { put("response_format", it) }
            }
        }.toString()

        val transport = RelayTransport.OpenAIChatCompletions
        val upstreamUrl = buildUrl(baseUrl, "/images/generations")
        val response = client.post(upstreamUrl) {
            applyRelayHeaders(apiKey = apiKey, requestOptions = requestOptions, transport = transport)
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (!response.status.isSuccess()) {
            throw mapRelayHttpError(
                response = response,
                upstreamUrl = upstreamUrl,
                requestOptions = requestOptions,
                modelID = modelID,
            )
        }

        val data = try {
            json.parseToJsonElement(response.bodyAsText()).jsonObject["data"]?.jsonArray
                ?: throw ProviderServiceError.EmptyResponse
        } catch (error: SerializationException) {
            throw SerializationException(MALFORMED_SCHEMA_RESPONSE_DETAIL, error)
        }
        val attachments = data.mapNotNull { element ->
            val obj = element.jsonObject
            val b64 = obj["b64_json"]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
            // A URL-shaped result is handed to ChatRepository's attachment pipeline to download.
            val url = obj["url"]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
            val payload = b64 ?: url ?: return@mapNotNull null
            Attachment(
                id = UUID.randomUUID().toString(),
                kind = AttachmentKind.Image,
                fileName = "generated_image.png",
                mimeType = obj["mime_type"]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
                    ?: "image/png",
                base64Data = payload,
            )
        }
        if (attachments.isEmpty()) throw ProviderServiceError.EmptyResponse

        return StreamEvent.Done(
            ProviderChatResult(text = "", attachments = attachments, servedModelID = modelID),
        )
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
        validateChatRequest(apiKey, modelID, requestOptions)
        val request = RelayTransportRequest(
            apiKey = apiKey,
            modelID = modelID,
            messages = messages,
            baseUrl = baseUrl,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
        )
        return when (resolveTransport(requestOptions)) {
            RelayTransport.LlamaCppNative -> sendLlamaCppNative(request)
            RelayTransport.OpenAIResponses -> openAIResponsesTransport.send(request)
            RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> openAIChatTransport.send(request)
            RelayTransport.GeminiGenerateContent -> geminiTransport.send(request)
            RelayTransport.AnthropicMessages -> anthropicMessagesTransport.send(request)
        }
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
    ): Flow<StreamEvent> {
        validateChatRequest(apiKey, modelID, requestOptions)
        val request = RelayTransportRequest(
            apiKey = apiKey,
            modelID = modelID,
            messages = messages,
            baseUrl = baseUrl,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
        )
        return when (resolveTransport(requestOptions)) {
            RelayTransport.LlamaCppNative -> streamLlamaCppNative(request)
            RelayTransport.OpenAIResponses -> openAIResponsesTransport.stream(request)
            RelayTransport.AnthropicMessages -> anthropicMessagesTransport.stream(request)
            RelayTransport.GeminiGenerateContent -> geminiTransport.stream(request)
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.Auto,
            -> openAIChatTransport.stream(request)
        }
    }

    suspend fun pingRelay(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        relayKind: RelayKind? = null,
    ) {
        validateRelayPingApiKey(apiKey, relayRequested.authMode)
        val transport = relayRequested.transport
            .takeIf { it != RelayTransport.Auto }
            ?: RelayTransport.OpenAIChatCompletions
        val requestOptions = ChatRequestOptions(
            relayRequested = relayRequested.copy(transport = transport),
        )

        when (transport) {
            RelayTransport.LlamaCppNative -> {
                val upstreamUrl = buildUrl(baseUrl, "/completion", requestOptions, apiKey, transport)
                val response = client.preparePost(upstreamUrl) {
                    applyRelayHeaders(apiKey, requestOptions, transport)
                    contentType(ContentType.Application.Json)
                    setBody("{\"prompt\":\"ping\",\"n_predict\":1,\"stream\":false}")
                }.execute()
                requireSuccessfulRelayPing(response, upstreamUrl, requestOptions, null, relayKind)
            }
            RelayTransport.OpenAIResponses -> {
                validateRelayPingModel(modelID)
                val upstreamUrl = buildUrl(baseUrl, "/responses", requestOptions, apiKey, transport)
                val body = buildString {
                    append("""{"model":${escapeJsonString(modelID)},""")
                    append(""""input":[{"role":"user","content":[{"type":"input_text","text":"ping"}]}],""")
                    append(""""max_output_tokens":1,"stream":false""")
                    if (relayRequested.disableResponseStorage == true) {
                        append(""","store":false""")
                    }
                    append("}")
                }
                val response = client.preparePost(upstreamUrl) {
                    applyRelayHeaders(apiKey, requestOptions, transport)
                    contentType(ContentType.Application.Json)
                    setBody(body)
                }.execute()
                requireSuccessfulRelayPing(response, upstreamUrl, requestOptions, modelID, relayKind)
            }
            RelayTransport.AnthropicMessages -> {
                validateRelayPingModel(modelID)
                val upstreamUrl = buildAnthropicUrl(baseUrl, requestOptions, apiKey, transport)
                val response = client.preparePost(upstreamUrl) {
                    applyRelayHeaders(apiKey, requestOptions, transport)
                    contentType(ContentType.Application.Json)
                    setBody(ProviderValidationStrategy.anthropicBody(ProviderKind.Anthropic, modelID))
                }.execute()
                requireSuccessfulRelayPing(response, upstreamUrl, requestOptions, modelID, relayKind)
            }
            RelayTransport.GeminiGenerateContent -> {
                validateRelayPingModel(modelID)
                val upstreamUrl = buildGeminiUrl(baseUrl, modelID, false, requestOptions, apiKey)
                val response = client.preparePost(upstreamUrl) {
                    applyRelayHeaders(apiKey, requestOptions, transport)
                    contentType(ContentType.Application.Json)
                    setBody(ProviderValidationStrategy.geminiBody(ProviderKind.Gemini))
                }.execute()
                requireSuccessfulRelayPing(response, upstreamUrl, requestOptions, modelID, relayKind)
            }
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.Auto,
            -> {
                if (modelID.isBlank()) {
                    val upstreamUrl = buildUrl(baseUrl, "/models", requestOptions, apiKey, RelayTransport.OpenAIChatCompletions)
                    val response = client.get(upstreamUrl) {
                        applyRelayHeaders(apiKey, requestOptions, RelayTransport.OpenAIChatCompletions)
                    }
                    requireSuccessfulRelayPing(response, upstreamUrl, requestOptions, null, relayKind)
                } else {
                    val upstreamUrl = buildUrl(baseUrl, "/chat/completions", requestOptions, apiKey, RelayTransport.OpenAIChatCompletions)
                    val response = client.preparePost(upstreamUrl) {
                        applyRelayHeaders(apiKey, requestOptions, RelayTransport.OpenAIChatCompletions)
                        contentType(ContentType.Application.Json)
                        setBody(openAIChatPingBody(modelID))
                    }.execute()
                    requireSuccessfulRelayPing(response, upstreamUrl, requestOptions, modelID, relayKind)
                }
            }
        }
    }

    private suspend fun requireSuccessfulRelayPing(
        response: HttpResponse,
        upstreamUrl: String,
        requestOptions: ChatRequestOptions,
        modelID: String?,
        relayKind: RelayKind?,
    ) {
        if (!response.status.isSuccess()) {
            throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID, relayKind)
        }
        val body = response.bodyAsText()
        if (!isRelayGenerationSuccessResponse(body, response.contentType()?.toString())) {
            throw ProviderServiceError.RelayUpstream(
                statusCode = response.status.value,
                guidance = MALFORMED_SUCCESS_RESPONSE_GUIDANCE,
                detail = "The relay returned an HTML page instead of a generation response.",
            )
        }
    }

    override suspend fun sendOpenAIResponses(request: RelayTransportRequest): StreamEvent.Done =
        sendResponses(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            supportsImageGen = request.supportsImageGen,
            reasoningMode = request.reasoningMode,
            webSearchEnabled = request.webSearchEnabled,
            requestOptions = request.requestOptions,
        )

    override fun streamOpenAIResponses(request: RelayTransportRequest): Flow<StreamEvent> =
        streamResponses(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            supportsImageGen = request.supportsImageGen,
            reasoningMode = request.reasoningMode,
            webSearchEnabled = request.webSearchEnabled,
            requestOptions = request.requestOptions,
        )

    override suspend fun sendOpenAIChat(request: RelayTransportRequest): StreamEvent.Done =
        sendOpenAIChat(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            reasoningMode = request.reasoningMode,
            requestOptions = request.requestOptions,
        )

    override fun streamOpenAIChat(request: RelayTransportRequest): Flow<StreamEvent> =
        streamOpenAIChat(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            reasoningMode = request.reasoningMode,
            requestOptions = request.requestOptions,
        )

    override suspend fun sendAnthropicMessages(request: RelayTransportRequest): StreamEvent.Done =
        sendAnthropic(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            reasoningMode = request.reasoningMode,
            requestOptions = request.requestOptions,
        )

    override fun streamAnthropicMessages(request: RelayTransportRequest): Flow<StreamEvent> =
        streamAnthropic(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            reasoningMode = request.reasoningMode,
            requestOptions = request.requestOptions,
        )

    override suspend fun sendGemini(request: RelayTransportRequest): StreamEvent.Done =
        sendGemini(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            supportsImageGen = request.supportsImageGen,
            reasoningMode = request.reasoningMode,
            webSearchEnabled = request.webSearchEnabled,
            requestOptions = request.requestOptions,
        )

    override fun streamGemini(request: RelayTransportRequest): Flow<StreamEvent> =
        streamGemini(
            apiKey = request.apiKey,
            modelID = request.modelID,
            messages = request.messages,
            baseUrl = request.baseUrl,
            supportsImageGen = request.supportsImageGen,
            reasoningMode = request.reasoningMode,
            webSearchEnabled = request.webSearchEnabled,
            requestOptions = request.requestOptions,
        )

    private suspend fun sendOpenAIChat(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        return withRelayOpenAIXHighFallback(
            transport = RelayTransport.OpenAIChatCompletions,
            requestOptions = requestOptions,
            reasoningMode = reasoningMode,
        ) { reasoningEffortOverride ->
            val transport = RelayTransport.OpenAIChatCompletions
            val upstreamUrl = buildUrl(baseUrl, "/chat/completions", requestOptions, apiKey, transport)
            val requestBody = buildOpenAIChatBody(
                modelID = modelID,
                messages = messages,
                stream = false,
                reasoningMode = reasoningMode,
                requestOptions = requestOptions,
                reasoningEffortOverride = reasoningEffortOverride,
                capabilityProjection = requestCapabilityProjection(
                    requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages,
                ),
            )

            var result: StreamEvent.Done? = null
            // Dropping a rejected parameter is the inner layer of each HTTP attempt: after the
            // outer layer has rebuilt the body for an xhigh downgrade, every new body gets a fresh
            // chance to have parameters stripped. The rejected-parameter classifier does not
            // recognise the wording of an xhigh value rejection, so the two layers never swallow
            // each other's cases.
            UnsupportedParamRetry.run(
                ProviderKind.Relay,
                modelID,
                requestBody,
                requestOptions = requestOptions,
                identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl),
            ) { requestBodyAttempt ->
                val statement = client.preparePost(upstreamUrl) {
                    applyRelayHeaders(apiKey, requestOptions, transport)
                    contentType(ContentType.Application.Json)
                    setBody(requestBodyAttempt)
                }

                requestOptions.capabilityExecutionCollector?.confirmDispatched()
                statement.execute { response ->
                    if (!response.status.isSuccess()) {
                        throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                    }

                    val parsed = decodeRelaySuccessResponse<ChatCompletionResponse>(response)
                    val choice = parsed.choices.firstOrNull() ?: throw ProviderServiceError.EmptyResponse
                    val text = choice.message.content.trim()
                    if (text.isEmpty()) throw ProviderServiceError.EmptyResponse

                    val breakdown = openAIChatUsageBreakdown(
                        promptTokens = parsed.usage?.prompt_tokens ?: 0,
                        completionTokens = parsed.usage?.completion_tokens ?: 0,
                        cachedInputTokens = parsed.usage?.prompt_tokens_details?.cached_tokens,
                        reasoningTokens = parsed.usage?.completion_tokens_details?.reasoning_tokens,
                    )
                    val (cost, source) = computeRelayCost(modelID, RelayTransport.OpenAIChatCompletions, breakdown)
                    result = StreamEvent.Done(
                        ProviderChatResult(
                            text = text,
                            promptTokens = parsed.usage?.prompt_tokens ?: 0,
                            completionTokens = parsed.usage?.completion_tokens ?: 0,
                            estimatedCost = cost,
                            cachedInputTokens = breakdown.reportedCachedInputTokens,
                            costSource = source.name,
                        ),
                    )
                }
            }
            result ?: throw ProviderServiceError.EmptyResponse
        }
    }

    private fun streamOpenAIChat(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        emitAll(
            withRelayOpenAIXHighFallbackFlow(
                transport = RelayTransport.OpenAIChatCompletions,
                requestOptions = requestOptions,
                reasoningMode = reasoningMode,
            ) { reasoningEffortOverride ->
                flow {
                    val transport = RelayTransport.OpenAIChatCompletions
                    val upstreamUrl = buildUrl(baseUrl, "/chat/completions", requestOptions, apiKey, transport)
                    val requestBody = buildOpenAIChatBody(
                        modelID = modelID,
                        messages = messages,
                        stream = true,
                        reasoningMode = reasoningMode,
                        requestOptions = requestOptions,
                        reasoningEffortOverride = reasoningEffortOverride,
                        capabilityProjection = requestCapabilityProjection(
                            requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages,
                        ),
                    )

                    // Parse citations with the chat-completions strategy plus the streamShape from
                    // the webSearchProfile the user selected.
                    val citationCtx = resolveCitationContext(
                        requestOptions = requestOptions,
                        fallbackTransport = transport,
                        webSearchEnabled = requestOptions.relayRequested?.hasWebSearch == true,
                    )
                    val toolCallParser = NativeToolCallParser(NativeToolProtocol.OpenAIChat)

                    // The self-healing retry sits in the inner layer: the status decision completes
                    // before anything is emitted, so a retry cannot emit the same tokens twice.
                    UnsupportedParamRetry.run(
                        ProviderKind.Relay,
                        modelID,
                        requestBody,
                        requestOptions = requestOptions,
                        identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl),
                    ) { requestBodyAttempt ->
                        val statement = client.preparePost(upstreamUrl) {
                            applyRelayHeaders(apiKey, requestOptions, transport)
                            contentType(ContentType.Application.Json)
                            setBody(requestBodyAttempt)
                        }

                        requestOptions.capabilityExecutionCollector?.confirmDispatched()
                        statement.execute { response ->
                            if (!response.status.isSuccess()) {
                                throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                            }

                            var accumulatedText = ""
                            var lastUsage: Usage? = null

                            SseParser.parseOpenAICompatibleMulti(
                                response = response,
                                json = json,
                                onChunk = { payload ->
                                    val events = mutableListOf<StreamEvent>()
                                    runCatching { json.parseToJsonElement(payload).jsonObject }
                                        .getOrNull()
                                        ?.let { toolCallParser.parse(null, it) }
                                        ?.takeIf { it.isNotEmpty() }
                                        ?.let { events += StreamEvent.ToolCallDeltas(it) }
                                    val chunk = json.decodeFromString<StreamChunk>(payload)
                                    chunk.usage?.let { lastUsage = it }

                                    // Citation parsing; the strategy already wraps this in runCatching.
                                    val cits = runCatching { citationCtx.strategy.parseCitations(payload, citationCtx.shape) }
                                        .getOrNull()
                                        .orEmpty()
                                    if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)

                                    chunk.choices?.firstOrNull()?.delta?.content?.takeIf { it.isNotEmpty() }?.let { delta ->
                                        accumulatedText += delta
                                        events += StreamEvent.Delta(delta)
                                    }
                                    chunk.choices?.firstOrNull()?.delta?.images.orEmpty().forEach { image ->
                                        image.image_url?.url?.takeIf { it.isNotBlank() }?.let { url ->
                                            events += StreamEvent.ImagePart(
                                                Attachment(
                                                    id = UUID.randomUUID().toString(),
                                                    kind = AttachmentKind.Image,
                                                    fileName = "generated_image.png",
                                                    mimeType = "image/png",
                                                    base64Data = url,
                                                ),
                                            )
                                        }
                                    }
                                    events
                                },
                                onDone = {
                                    val breakdown = openAIChatUsageBreakdown(
                                        promptTokens = lastUsage?.prompt_tokens ?: 0,
                                        completionTokens = lastUsage?.completion_tokens ?: 0,
                                        cachedInputTokens = lastUsage?.prompt_tokens_details?.cached_tokens,
                                        reasoningTokens = lastUsage?.completion_tokens_details?.reasoning_tokens,
                                    )
                                    val (cost, source) = computeRelayCost(modelID, RelayTransport.OpenAIChatCompletions, breakdown)
                                    StreamEvent.Done(
                                        ProviderChatResult(
                                            text = accumulatedText.trim(),
                                            promptTokens = lastUsage?.prompt_tokens ?: 0,
                                            completionTokens = lastUsage?.completion_tokens ?: 0,
                                            estimatedCost = cost,
                                            cachedInputTokens = breakdown.reportedCachedInputTokens,
                                            costSource = source.name,
                                        ),
                                    )
                                },
                            ).collect { emit(it) }
                        }
                    }
                }
            },
        )
    }

    /**
     * llama.cpp native `/completion` is wired into the same self-healing net: `n_predict` and
     * `temperature` in the body, along with the generation parameters injected by
     * `GenerationParameterResolver`, are all optional, and one version bump of the local engine can
     * be enough for it to reject them with a 400.
     * The preflight stays in the outer layer, because it is a local context check rather than a
     * single HTTP attempt.
     */
    private suspend fun sendLlamaCppNative(request: RelayTransportRequest): StreamEvent.Done {
        preflightLlamaCppNative(request)
        val transport = RelayTransport.LlamaCppNative
        val upstreamUrl = buildUrl(request.baseUrl, "/completion", request.requestOptions, request.apiKey, transport)
        val requestBody = buildLlamaCppNativeBody(
            request.messages,
            stream = false,
            requestOptions = request.requestOptions,
            capabilityProjection = requestCapabilityProjection(
                request.requestOptions, request.modelID, transport, upstreamUrl, ReasoningMode.Automatic, request.messages,
            ),
        )

        var result: StreamEvent.Done? = null
        UnsupportedParamRetry.run(
            ProviderKind.Relay,
            request.modelID,
            requestBody,
            requestOptions = request.requestOptions,
            identity = runtimeSelfHealIdentity(request.requestOptions, request.modelID, transport, upstreamUrl),
        ) { requestBodyAttempt ->
            val response = client.post(upstreamUrl) {
                applyRelayHeaders(request.apiKey, request.requestOptions, transport)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }
            if (!response.status.isSuccess()) {
                throw mapRelayHttpError(response, upstreamUrl, request.requestOptions, null)
            }
            val content = llamaCppContent(response.bodyAsText(), relayCredentialMaterial(response))
            if (content.isBlank()) throw ProviderServiceError.EmptyResponse
            result = StreamEvent.Done(ProviderChatResult(text = content.trim(), estimatedCost = 0.0))
        }
        return result ?: throw ProviderServiceError.EmptyResponse
    }

    private fun streamLlamaCppNative(request: RelayTransportRequest): Flow<StreamEvent> = flow {
        preflightLlamaCppNative(request)
        val transport = RelayTransport.LlamaCppNative
        val upstreamUrl = buildUrl(request.baseUrl, "/completion", request.requestOptions, request.apiKey, transport)
        val requestBody = buildLlamaCppNativeBody(
            request.messages,
            stream = true,
            requestOptions = request.requestOptions,
            capabilityProjection = requestCapabilityProjection(
                request.requestOptions, request.modelID, transport, upstreamUrl, ReasoningMode.Automatic, request.messages,
            ),
        )

        UnsupportedParamRetry.run(
            ProviderKind.Relay,
            request.modelID,
            requestBody,
            requestOptions = request.requestOptions,
            identity = runtimeSelfHealIdentity(request.requestOptions, request.modelID, transport, upstreamUrl),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(upstreamUrl) {
                applyRelayHeaders(request.apiKey, request.requestOptions, transport)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }
            request.requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    throw mapRelayHttpError(response, upstreamUrl, request.requestOptions, null)
                }
                var accumulated = ""
                response.bodyAsChannel().toInputStream().bufferedReader(StandardCharsets.UTF_8).use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        val payload = line.removePrefix("data: ").trim()
                        if (payload.isEmpty() || payload == "[DONE]") continue
                        val delta = llamaCppContent(payload, relayCredentialMaterial(response))
                        if (delta.isNotEmpty()) {
                            accumulated += delta
                            emit(StreamEvent.Delta(delta))
                        }
                    }
                }
                emit(StreamEvent.Done(ProviderChatResult(text = accumulated.trim(), estimatedCost = 0.0)))
            }
        }
    }

    private suspend fun preflightLlamaCppNative(request: RelayTransportRequest) {
        val endpoint = request.baseUrl?.takeIf { it.isNotBlank() } ?: return
        val result = localRuntimeClient.preflight(
            endpoint = endpoint,
            engine = LocalEngineKind.LlamaCpp,
            prompt = buildLlamaCppPrompt(request.messages, request.requestOptions),
            contextLimit = request.requestOptions.activeModel?.contextLength,
        )
        if (result is LocalPromptPreflight.Supported && result.exceedsContext) {
            throw ProviderServiceError.Upstream(statusCode = 400, detail = "context_length_exceeded")
        }
    }

    private fun llamaCppContent(payload: String, credentials: Collection<String>): String {
        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
            ?: throw ProviderServiceError.Network("Invalid llama.cpp response.")
        root["content"]?.jsonPrimitive?.content?.let { return it }
        root["error"]?.jsonObject?.get("message")?.jsonPrimitive?.content?.let {
            val safeDetail = RelayDebugSnippet.extract(payload, redacting = credentials)
                .orEmpty()
                .ifBlank { "The custom LLM returned an error." }
            throw ProviderServiceError.Upstream(statusCode = 200, detail = safeDetail)
        }
        return ""
    }

    private suspend fun sendResponses(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        return withRelayResponsesFallbacks(
            requestOptions = requestOptions,
            reasoningMode = reasoningMode,
        ) { hints ->
            val transport = RelayTransport.OpenAIResponses
            val upstreamUrl = buildUrl(baseUrl, "/responses", requestOptions, apiKey, transport)
            val requestBody = buildResponsesBody(
                modelID = modelID,
                messages = messages,
                stream = false,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                requestOptions = requestOptions,
                reasoningEffortOverride = hints.reasoningEffortOverride,
                removeTools = hints.removeTools,
                capabilityProjection = requestCapabilityProjection(
                    requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages, webSearchEnabled,
                ),
            )

            var result: StreamEvent.Done? = null
            // The older tool and xhigh classifications express a structured rejection through an
            // internal signal only; the outer layer surfaces it and does not send a second request.
            UnsupportedParamRetry.run(
                ProviderKind.Relay,
                modelID,
                requestBody,
                requestOptions = requestOptions,
                identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl),
            ) { requestBodyAttempt ->
                val statement = client.preparePost(upstreamUrl) {
                    applyRelayHeaders(apiKey, requestOptions, transport)
                    contentType(ContentType.Application.Json)
                    setBody(requestBodyAttempt)
                }

                requestOptions.capabilityExecutionCollector?.confirmDispatched()
                statement.execute { response ->
                    if (!response.status.isSuccess()) {
                        val statusCode = response.status.value
                        val rawBody = response.bodyAsText()
                        if (statusCode in 400..499) {
                            val payload = RelayErrorMapper.parseUpstreamErrorPayload(rawBody)
                            if (!hints.removeTools
                                && RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, statusCode)
                            ) {
                                throw RelayResponsesRejectedSettingSignal(RelayRetryHints(removeTools = true))
                            }
                            if (hints.reasoningEffortOverride == null
                                && RelayErrorMapper.isReasoningEffortXHighError(payload, statusCode)
                            ) {
                                throw RelayResponsesRejectedSettingSignal(
                                    RelayRetryHints(reasoningEffortOverride = RelayReasoningEffort.High.value)
                                )
                            }
                        }
                        throw mapRelayHttpErrorBody(
                            statusCode,
                            rawBody,
                            upstreamUrl,
                            requestOptions,
                            modelID,
                            credentials = relayCredentialMaterial(response),
                        )
                    }

                    val parsed = decodeRelaySuccessResponse<ResponsesResponse>(response)
                    val text = parsed.resolvedText.trim()
                    val attachments = parsed.resolvedAttachments
                    if (text.isEmpty() && attachments.isEmpty()) throw ProviderServiceError.EmptyResponse

                    val breakdown = openAIResponsesUsageBreakdown(
                        inputTokens = parsed.usage?.input_tokens,
                        outputTokens = parsed.usage?.output_tokens,
                        cachedInputTokens = parsed.usage?.input_tokens_details?.cached_tokens,
                        reasoningTokens = parsed.usage?.output_tokens_details?.reasoning_tokens,
                    )
                    val (cost, source) = computeRelayCost(modelID, RelayTransport.OpenAIResponses, breakdown)
                    result = StreamEvent.Done(
                        ProviderChatResult(
                            text = text,
                            promptTokens = parsed.usage?.input_tokens ?: 0,
                            completionTokens = parsed.usage?.output_tokens ?: 0,
                            estimatedCost = cost,
                            attachments = attachments.ifEmpty { null },
                            cachedInputTokens = breakdown.reportedCachedInputTokens,
                            costSource = source.name,
                        ),
                    )
                }
            }

            result ?: throw ProviderServiceError.EmptyResponse
        }
    }

    /// Converts a rejected-setting signal into a plain upstream error. Exactly one unchanged
    /// upstream attempt is made; an optional setting the endpoint refuses is surfaced to the
    /// user rather than silently stripped and retried.
    private suspend fun <T> withRelayResponsesFallbacks(
        @Suppress("UNUSED_PARAMETER") requestOptions: ChatRequestOptions,
        @Suppress("UNUSED_PARAMETER") reasoningMode: ReasoningMode,
        block: suspend (RelayRetryHints) -> T,
    ): T {
        return try {
            block(RelayRetryHints())
        } catch (_: RelayResponsesRejectedSettingSignal) {
            throw ProviderServiceError.Upstream(
                statusCode = 400,
                detail = "The relay rejected an optional request setting.",
            )
        }
    }

    private fun streamResponses(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        emitAll(
            withRelayResponsesFallbacksFlow(
                requestOptions = requestOptions,
                reasoningMode = reasoningMode,
            ) { hints ->
                flow {
                    val transport = RelayTransport.OpenAIResponses
                    val upstreamUrl = buildUrl(baseUrl, "/responses", requestOptions, apiKey, transport)
                    val requestBody = buildResponsesBody(
                        modelID = modelID,
                        messages = messages,
                        stream = true,
                        supportsImageGen = supportsImageGen,
                        reasoningMode = reasoningMode,
                        webSearchEnabled = webSearchEnabled,
                        requestOptions = requestOptions,
                        reasoningEffortOverride = hints.reasoningEffortOverride,
                        removeTools = hints.removeTools,
                        capabilityProjection = requestCapabilityProjection(
                            requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages, webSearchEnabled,
                        ),
                    )

                    // The status decision completes before anything is emitted, so the inner signal
                    // can only ever be surfaced by the outer layer.
                    UnsupportedParamRetry.run(
                        ProviderKind.Relay,
                        modelID,
                        requestBody,
                        requestOptions = requestOptions,
                        identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl),
                    ) { requestBodyAttempt ->
                        val statement = client.preparePost(upstreamUrl) {
                            applyRelayHeaders(apiKey, requestOptions, transport)
                            contentType(ContentType.Application.Json)
                            setBody(requestBodyAttempt)
                        }

                        requestOptions.capabilityExecutionCollector?.confirmDispatched()
                        statement.execute { response ->
                            if (!response.status.isSuccess()) {
                                val statusCode = response.status.value
                                val rawBody = response.bodyAsText()
                                // On an HTTP 4xx the rejected setting is recorded structurally, and
                                // the outer layer surfaces exactly one failure.
                                if (statusCode in 400..499) {
                                    val payload = RelayErrorMapper.parseUpstreamErrorPayload(rawBody)
                                    if (!hints.removeTools
                                        && RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, statusCode)
                                    ) {
                                        throw RelayResponsesRejectedSettingSignal(RelayRetryHints(removeTools = true))
                                    }
                                    if (hints.reasoningEffortOverride == null
                                        && RelayErrorMapper.isReasoningEffortXHighError(payload, statusCode)
                                    ) {
                                        throw RelayResponsesRejectedSettingSignal(
                                            RelayRetryHints(reasoningEffortOverride = RelayReasoningEffort.High.value)
                                        )
                                    }
                                }
                                throw mapRelayHttpErrorBody(
                                    statusCode,
                                    rawBody,
                                    upstreamUrl,
                                    requestOptions,
                                    modelID,
                                    credentials = relayCredentialMaterial(response),
                                )
                            }

                            // Parse citations with the Responses strategy plus the streamShape from
                            // the webSearchProfile the user selected.
                            val citationCtx = resolveCitationContext(
                                requestOptions = requestOptions,
                                fallbackTransport = transport,
                                webSearchEnabled = webSearchEnabled,
                            )

                            var accumulatedText = ""
                            var lastUsage: ResponsesUsage? = null
                            var firstContentEmitted = false
                            val emittedImageIds = mutableSetOf<String>()
                            var currentEvent = ""
                            val toolCallParser = NativeToolCallParser(NativeToolProtocol.OpenAIResponses)

                            response.bodyAsChannel()
                                .toInputStream()
                                .bufferedReader(StandardCharsets.UTF_8)
                                .use { reader ->
                                    while (true) {
                                        val line = reader.readLine() ?: break
                                        when {
                                            line.startsWith("event: ") -> currentEvent = line.removePrefix("event: ").trim()
                                            line.startsWith("data: ") -> {
                                                val payload = line.removePrefix("data: ").trim()
                                                if (payload.isEmpty() || payload == "[DONE]") {
                                                    currentEvent = ""
                                                    continue
                                                }

                                                // Citation parsing: annotations can hide in several
                                                // different Responses events, so the url_citation
                                                // nodes are scanned recursively, the same way
                                                // OpenAIService does it.
                                                val cits = runCatching { citationCtx.strategy.parseCitations(payload, citationCtx.shape) }
                                                    .getOrNull()
                                                    .orEmpty()
                                                if (cits.isNotEmpty()) emit(StreamEvent.Citations(cits))
                                                runCatching { json.parseToJsonElement(payload).jsonObject }
                                                    .getOrNull()
                                                    ?.let { toolCallParser.parse(currentEvent, it) }
                                                    ?.takeIf { it.isNotEmpty() }
                                                    ?.let { emit(StreamEvent.ToolCallDeltas(it)) }

                                                when (currentEvent) {
                                                    "response.output_text.delta" -> {
                                                        val delta = json.decodeFromString<ResponsesStreamDelta>(payload).delta.orEmpty()
                                                        if (delta.isNotEmpty()) {
                                                            accumulatedText += delta
                                                            firstContentEmitted = true
                                                            emit(StreamEvent.Delta(delta))
                                                        }
                                                    }
                                                    "response.output_image.done",
                                                    "response.image_generation_call.completed",
                                                    -> {
                                                        val imageDone = json.decodeFromString<ResponsesStreamImageDone>(payload)
                                                        val itemId = imageDone.item_id ?: imageDone.id
                                                        if (!imageDone.result.isNullOrBlank() && (itemId == null || emittedImageIds.add(itemId))) {
                                                            firstContentEmitted = true
                                                            emit(buildImageEvent(imageDone.result))
                                                        }
                                                    }
                                                    "response.output_item.done" -> {
                                                        val itemDone = json.decodeFromString<ResponsesStreamOutputItemDone>(payload)
                                                        val item = itemDone.item
                                                        val itemId = item?.id
                                                        if (item?.type == "image_generation_call" &&
                                                            !item.result.isNullOrBlank() &&
                                                            (itemId == null || emittedImageIds.add(itemId))
                                                        ) {
                                                            firstContentEmitted = true
                                                            emit(buildImageEvent(item.result))
                                                        }
                                                    }
                                                    "response.completed" -> {
                                                        lastUsage = json.decodeFromString<ResponsesStreamCompleted>(payload).resolvedUsage
                                                    }
                                                    "response.failed", "error" -> {
                                                        // A structured image-tool rejection seen
                                                        // before any content has been emitted is
                                                        // only surfaced, never resent.
                                                        val streamPayload = parseStreamErrorPayload(payload)
                                                        if (!firstContentEmitted && !hints.removeTools
                                                            && RelayErrorMapper.isImageGenerationToolUnsupportedError(streamPayload, 400)
                                                        ) {
                                                            throw RelayResponsesRejectedSettingSignal(RelayRetryHints(removeTools = true))
                                                        }
                                                        throw ProviderServiceError.Upstream(
                                                            statusCode = 200,
                                                            // The raw message only feeds the
                                                            // structural classification above; it
                                                            // is never persisted or shown.
                                                            detail = "The custom LLM Responses stream reported a failure.",
                                                        )
                                                    }
                                                }

                                                currentEvent = ""
                                            }
                                        }
                                    }
                                }

                            val breakdown = openAIResponsesUsageBreakdown(
                                inputTokens = lastUsage?.input_tokens,
                                outputTokens = lastUsage?.output_tokens,
                                cachedInputTokens = lastUsage?.input_tokens_details?.cached_tokens,
                                reasoningTokens = lastUsage?.output_tokens_details?.reasoning_tokens,
                            )
                            val (cost, source) = computeRelayCost(modelID, RelayTransport.OpenAIResponses, breakdown)
                            emit(
                                StreamEvent.Done(
                                    ProviderChatResult(
                                        text = accumulatedText.trim(),
                                        promptTokens = lastUsage?.input_tokens ?: 0,
                                        completionTokens = lastUsage?.output_tokens ?: 0,
                                        estimatedCost = cost,
                                        cachedInputTokens = breakdown.reportedCachedInputTokens,
                                        costSource = source.name,
                                    ),
                                ),
                            )
                        }
                    }
                }
            },
        )
    }

    // Parses an SSE error payload from inside a stream by reusing
    // RelayErrorMapper.parseUpstreamErrorPayload, which already handles both `event: error` with a
    // top-level error and `event: response.failed` with response.error.
    private fun parseStreamErrorPayload(payload: String): RelayUpstreamErrorPayload? =
        RelayErrorMapper.parseUpstreamErrorPayload(payload)

    // Equivalent to mapRelayHttpError but takes an already-read raw body, so the channel is not
    // read twice.
    private fun mapRelayHttpErrorBody(
        statusCode: Int,
        body: String,
        upstreamUrl: String,
        requestOptions: ChatRequestOptions,
        modelID: String?,
        relayKind: RelayKind? = null,
        credentials: Collection<String> = emptyList(),
    ): ProviderServiceError {
        val transport = requestOptions.relayRequested?.transport
            ?.takeIf { it != RelayTransport.Auto }
            ?: RelayTransport.OpenAIChatCompletions
        return RelayErrorMapper.mapOrDefault(
            status = statusCode,
            body = body,
            upstreamUrl = upstreamUrl,
            context = RelayErrorContext(
                relayKind = relayKind,
                transport = transport,
                authMode = resolveAuthMode(requestOptions, transport),
                modelID = modelID,
                codexCompatIdentity = requestOptions.relayRequested?.codexCompatIdentity,
            ),
            credentials = credentials,
        )
    }

    /**
     * Streaming counterpart: signal classification is retained for compatibility diagnostics,
     * but it cannot re-enter [block] with stripped tools or downgraded reasoning.
     */
    private fun withRelayResponsesFallbacksFlow(
        @Suppress("UNUSED_PARAMETER") requestOptions: ChatRequestOptions,
        @Suppress("UNUSED_PARAMETER") reasoningMode: ReasoningMode,
        block: suspend (RelayRetryHints) -> Flow<StreamEvent>,
    ): Flow<StreamEvent> = flow {
        try {
            emitAll(block(RelayRetryHints()))
        } catch (_: RelayResponsesRejectedSettingSignal) {
            throw ProviderServiceError.Upstream(
                statusCode = 400,
                detail = "The relay rejected an optional request setting.",
            )
        }
    }

    // Internal sentinel: the HTTP and in-stream layers use it to report a structured rejection to
    // the single-attempt wrapper. It never escapes to the UI.
    private class RelayResponsesRejectedSettingSignal(val hints: RelayRetryHints) : Exception()

    private fun buildImageEvent(result: String?): StreamEvent.ImagePart {
        val payload = result.orEmpty()
        val normalized = if (payload.startsWith("data:") || payload.startsWith("http")) {
            payload
        } else {
            "data:image/png;base64,$payload"
        }
        return StreamEvent.ImagePart(
            Attachment(
                id = UUID.randomUUID().toString(),
                kind = AttachmentKind.Image,
                fileName = "generated_image.png",
                mimeType = "image/png",
                base64Data = normalized.removePrefix("data:image/png;base64,").takeIf { !normalized.startsWith("http") }
                    ?: normalized,
            ),
        )
    }

    private suspend fun sendAnthropic(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        val transport = RelayTransport.AnthropicMessages
        val upstreamUrl = buildAnthropicUrl(baseUrl, requestOptions, apiKey, transport)
        val requestBody = buildAnthropicBody(
            modelID,
            messages,
            false,
            reasoningMode,
            requestOptions,
            requestCapabilityProjection(requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages),
        )

        var result: StreamEvent.Done? = null
        UnsupportedParamRetry.run(
            ProviderKind.Relay,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl.toString()),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(upstreamUrl) {
                applyRelayHeaders(apiKey, requestOptions, transport)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                }

                val parsed = decodeRelaySuccessResponse<AnthropicResponse>(response)
                val text = parsed.resolvedText.trim()
                if (text.isEmpty()) throw ProviderServiceError.EmptyResponse

                val breakdown = anthropicUsageBreakdown(
                    inputTokens = parsed.usage?.input_tokens,
                    outputTokens = parsed.usage?.output_tokens,
                    cacheReadInputTokens = parsed.usage?.cache_read_input_tokens,
                    cacheCreation5mInputTokens = parsed.usage?.cache_creation?.ephemeral_5m_input_tokens
                        ?: parsed.usage?.cache_creation_input_tokens,
                    cacheCreation1hInputTokens = parsed.usage?.cache_creation?.ephemeral_1h_input_tokens,
                )
                val (cost, source) = computeRelayCost(modelID, RelayTransport.AnthropicMessages, breakdown)
                // promptTokens, the total input shown in the UI, is input + cache_read + cache_create.
                val totalPrompt = breakdown.promptTokens + breakdown.cachedInputTokens +
                    breakdown.cacheCreation5mTokens + breakdown.cacheCreation1hTokens
                result = StreamEvent.Done(
                    ProviderChatResult(
                        text = text,
                        promptTokens = totalPrompt,
                        completionTokens = breakdown.completionTokens,
                        estimatedCost = cost,
                        cachedInputTokens = breakdown.reportedCachedInputTokens,
                        cacheCreation5mTokens = breakdown.reportedCacheCreation5mTokens,
                        cacheCreation1hTokens = breakdown.reportedCacheCreation1hTokens,
                        costSource = source.name,
                    ),
                )
            }
        }

        return result ?: throw ProviderServiceError.EmptyResponse
    }

    private fun streamAnthropic(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        val transport = RelayTransport.AnthropicMessages
        val upstreamUrl = buildAnthropicUrl(baseUrl, requestOptions, apiKey, transport)
        val requestBody = buildAnthropicBody(
            modelID,
            messages,
            true,
            reasoningMode,
            requestOptions,
            requestCapabilityProjection(requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages),
        )

        // Parse citations with the Anthropic strategy plus the streamShape from the
        // webSearchProfile the user selected.
        val citationCtx = resolveCitationContext(
            requestOptions = requestOptions,
            fallbackTransport = transport,
            webSearchEnabled = requestOptions.relayRequested?.hasWebSearch == true,
        )

        UnsupportedParamRetry.run(
            ProviderKind.Relay,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl.toString()),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(upstreamUrl) {
                applyRelayHeaders(apiKey, requestOptions, transport)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                }

                var accumulatedText = ""
                var inputTokens = 0
                var outputTokens = 0
                // Nullable on purpose: we have to preserve whether the upstream reported the field
                // at all. Collapse it to 0 and an explicitly reported 0 becomes indistinguishable
                // from never having been reported.
                var cacheReadTokens: Int? = null
                var cacheCreation5m: Int? = null
                var cacheCreation1h: Int? = null
                val toolCallParser = NativeToolCallParser(NativeToolProtocol.AnthropicMessages)

                SseParser.parseAnthropicStreamMulti(
                    response = response,
                    json = json,
                    onEvent = { eventType, data ->
                        val events = mutableListOf<StreamEvent>()
                        runCatching { json.parseToJsonElement(data).jsonObject }
                            .getOrNull()
                            ?.let { toolCallParser.parse(eventType, it) }
                            ?.takeIf { it.isNotEmpty() }
                            ?.let { events += StreamEvent.ToolCallDeltas(it) }
                        // Any content_block_* event can carry a web_search_tool_result block, so
                        // citations are parsed from all of them.
                        if (eventType.startsWith("content_block")) {
                            val cits = runCatching { citationCtx.strategy.parseCitations(data, citationCtx.shape) }
                                .getOrNull()
                                .orEmpty()
                            if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)
                        }
                        when (eventType) {
                            "message_start" -> {
                                val usage = json.decodeFromString<MessageStartEvent>(data).message?.usage
                                inputTokens = usage?.input_tokens ?: 0
                                cacheReadTokens = usage?.cache_read_input_tokens
                                cacheCreation5m = usage?.cache_creation?.ephemeral_5m_input_tokens
                                    ?: usage?.cache_creation_input_tokens
                                cacheCreation1h = usage?.cache_creation?.ephemeral_1h_input_tokens
                            }
                            "content_block_delta" -> {
                                // As in AnthropicService, thinking tokens are emitted as Reasoning
                                // only and never appended to accumulatedText, which would otherwise
                                // pollute the body and the final Done text. The body branch
                                // deliberately does not insist on type=="text_delta": a sloppy
                                // relay may omit type entirely, so we keep the older behaviour of
                                // trusting the text field instead (signature_delta and similar have
                                // no text field and simply fall through).
                                val delta = json.decodeFromString<ContentDeltaEvent>(data).delta
                                if (delta?.type == "thinking_delta") {
                                    val thinking = delta.thinking
                                    if (!thinking.isNullOrEmpty()) {
                                        events += StreamEvent.Reasoning(thinking)
                                    }
                                } else {
                                    val text = delta?.text
                                    if (!text.isNullOrEmpty()) {
                                        accumulatedText += text
                                        events += StreamEvent.Delta(text)
                                    }
                                }
                            }
                            "message_delta" -> {
                                val deltaUsage = json.decodeFromString<MessageDeltaEvent>(data).usage
                                outputTokens = deltaUsage?.output_tokens ?: outputTokens
                                deltaUsage?.cache_read_input_tokens?.let { cacheReadTokens = it }
                                deltaUsage?.cache_creation?.ephemeral_5m_input_tokens?.let { cacheCreation5m = it }
                                deltaUsage?.cache_creation?.ephemeral_1h_input_tokens?.let { cacheCreation1h = it }
                            }
                            else -> { /* no-op */ }
                        }
                        events
                    },
                    onDone = {
                        val breakdown = anthropicUsageBreakdown(
                            inputTokens = inputTokens,
                            outputTokens = outputTokens,
                            cacheReadInputTokens = cacheReadTokens,
                            cacheCreation5mInputTokens = cacheCreation5m,
                            cacheCreation1hInputTokens = cacheCreation1h,
                        )
                        val (cost, source) = computeRelayCost(modelID, RelayTransport.AnthropicMessages, breakdown)
                        StreamEvent.Done(
                            ProviderChatResult(
                                text = accumulatedText.trim(),
                                // Anthropic's input_tokens already excludes cached tokens, so the
                                // total input shown in the UI has to add the three back together.
                                promptTokens = breakdown.totalInputTokens,
                                completionTokens = outputTokens,
                                estimatedCost = cost,
                                cachedInputTokens = breakdown.reportedCachedInputTokens,
                                cacheCreation5mTokens = breakdown.reportedCacheCreation5mTokens,
                                cacheCreation1hTokens = breakdown.reportedCacheCreation1hTokens,
                                costSource = source.name,
                            ),
                        )
                    },
                ).collect { emit(it) }
            }
        }
    }

    /**
     * Gemini reports a safety block inside an HTTP 200 response, in finishReason or
     * promptFeedback.blockReason. Not throwing here degrades into a silent EmptyResponse. In line
     * with how in-stream errors are handled elsewhere this uses Upstream(200), which does not
     * trigger a retry.
     */
    private fun throwIfGeminiBlocked(parsed: GenerateResponse) {
        val blockReason = parsed.promptFeedback?.blockReason
        if (blockReason != null && blockReason in GEMINI_BLOCKED_REASONS) {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini blocked the prompt: $blockReason",
            )
        }
        val finishReason = parsed.candidates?.firstOrNull()?.finishReason
        if (finishReason != null && finishReason in GEMINI_BLOCKED_REASONS) {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini stopped generation: $finishReason",
            )
        }
    }

    private suspend fun sendGemini(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        val transport = RelayTransport.GeminiGenerateContent
        val upstreamUrl = buildGeminiUrl(baseUrl, modelID, false, requestOptions, apiKey)
        val requestBody = buildGeminiBody(
            messages,
            modelID,
            supportsImageGen,
            reasoningMode,
            webSearchEnabled,
            requestOptions,
            requestCapabilityProjection(requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages, webSearchEnabled),
        )

        var result: StreamEvent.Done? = null
        UnsupportedParamRetry.run(
            ProviderKind.Relay,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl.toString()),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(upstreamUrl) {
                applyRelayHeaders(apiKey, requestOptions, transport)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                }

                val parsed = decodeRelaySuccessResponse<GenerateResponse>(response)
                throwIfGeminiBlocked(parsed)
                val parts = parsed.candidates?.firstOrNull()?.content?.parts.orEmpty()
                val text = parts.mapNotNull { it.text }.joinToString("").trim()
                val attachments = parts.mapNotNull { part ->
                    part.inlineData?.takeIf { it.mimeType.startsWith("image/") }?.let { inline ->
                        Attachment(
                            id = UUID.randomUUID().toString(),
                            kind = AttachmentKind.Image,
                            fileName = "generated_image",
                            mimeType = inline.mimeType,
                            base64Data = inline.data,
                        )
                    }
                }
                if (text.isEmpty() && attachments.isEmpty()) throw ProviderServiceError.EmptyResponse

                val breakdown = geminiUsageBreakdown(
                    promptTokenCount = parsed.usageMetadata?.promptTokenCount,
                    candidatesTokenCount = parsed.usageMetadata?.candidatesTokenCount,
                    thoughtsTokenCount = parsed.usageMetadata?.thoughtsTokenCount,
                    cachedContentTokenCount = parsed.usageMetadata?.cachedContentTokenCount,
                )
                val (cost, source) = computeRelayCost(modelID, RelayTransport.GeminiGenerateContent, breakdown)
                result = StreamEvent.Done(
                    ProviderChatResult(
                        text = text,
                        promptTokens = parsed.usageMetadata?.promptTokenCount ?: 0,
                        completionTokens = breakdown.completionTokens,  // candidates + thoughts
                        estimatedCost = cost,
                        attachments = attachments.ifEmpty { null },
                        cachedInputTokens = breakdown.reportedCachedInputTokens,
                        costSource = source.name,
                    ),
                )
            }
        }
        return result ?: throw ProviderServiceError.EmptyResponse
    }

    private fun streamGemini(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        val transport = RelayTransport.GeminiGenerateContent
        val upstreamUrl = buildGeminiUrl(baseUrl, modelID, true, requestOptions, apiKey)
        val requestBody = buildGeminiBody(
            messages,
            modelID,
            supportsImageGen,
            reasoningMode,
            webSearchEnabled,
            requestOptions,
            requestCapabilityProjection(requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages, webSearchEnabled),
        )

        // Parse citations with the Gemini strategy plus the streamShape from the webSearchProfile
        // the user selected.
        val citationCtx = resolveCitationContext(
            requestOptions = requestOptions,
            fallbackTransport = transport,
            webSearchEnabled = webSearchEnabled,
        )

        UnsupportedParamRetry.run(
            ProviderKind.Relay,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = runtimeSelfHealIdentity(requestOptions, modelID, transport, upstreamUrl.toString()),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(upstreamUrl) {
                applyRelayHeaders(apiKey, requestOptions, transport)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                }

                var accumulatedText = ""
                var lastUsage: UsageMeta? = null
                val attachments = mutableListOf<Attachment>()
                val toolCallParser = NativeToolCallParser(NativeToolProtocol.GeminiGenerate)

                SseParser.parseGeminiStreamMulti(
                    response = response,
                    json = json,
                    onChunk = { payload ->
                        val events = mutableListOf<StreamEvent>()
                        runCatching { json.parseToJsonElement(payload).jsonObject }
                            .getOrNull()
                            ?.let { toolCallParser.parse(null, it) }
                            ?.takeIf { it.isNotEmpty() }
                            ?.let { events += StreamEvent.ToolCallDeltas(it) }
                        val chunk = json.decodeFromString<GenerateResponse>(payload)
                        // A blocking finishReason can arrive inside a 200 stream, so it has to be
                        // thrown explicitly rather than silently swallowed.
                        throwIfGeminiBlocked(chunk)
                        chunk.usageMetadata?.let { lastUsage = it }

                        // Citation parsing; the strategy already wraps this in runCatching.
                        val cits = runCatching { citationCtx.strategy.parseCitations(payload, citationCtx.shape) }
                            .getOrNull()
                            .orEmpty()
                        if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)

                        chunk.candidates?.firstOrNull()?.content?.parts.orEmpty().forEach { part ->
                            part.text?.takeIf { it.isNotEmpty() }?.let { text ->
                                accumulatedText += text
                                events += StreamEvent.Delta(text)
                            }
                            part.inlineData?.takeIf { it.mimeType.startsWith("image/") }?.let { inline ->
                                attachments += Attachment(
                                    id = UUID.randomUUID().toString(),
                                    kind = AttachmentKind.Image,
                                    fileName = "generated_image",
                                    mimeType = inline.mimeType,
                                    base64Data = inline.data,
                                )
                            }
                        }
                        events
                    },
                    onDone = {
                        val breakdown = geminiUsageBreakdown(
                            promptTokenCount = lastUsage?.promptTokenCount,
                            candidatesTokenCount = lastUsage?.candidatesTokenCount,
                            thoughtsTokenCount = lastUsage?.thoughtsTokenCount,
                            cachedContentTokenCount = lastUsage?.cachedContentTokenCount,
                        )
                        val (cost, source) = computeRelayCost(modelID, RelayTransport.GeminiGenerateContent, breakdown)
                        StreamEvent.Done(
                            ProviderChatResult(
                                text = accumulatedText.trim(),
                                promptTokens = lastUsage?.promptTokenCount ?: 0,
                                completionTokens = breakdown.completionTokens,
                                estimatedCost = cost,
                                attachments = attachments.ifEmpty { null },
                                cachedInputTokens = breakdown.reportedCachedInputTokens,
                                costSource = source.name,
                            ),
                        )
                    },
                ).collect { emit(it) }
            }
        }
    }

    private fun openAIChatPingBody(modelID: String): String =
        buildString {
            append("""{"model":${escapeJsonString(modelID)},""")
            append(""""stream":false,"max_tokens":1,""")
            append(""""messages":[{"role":"user","content":"ping"}]}""")
        }

    private fun buildGeminiUrl(
        baseUrl: String?,
        modelID: String,
        stream: Boolean,
        requestOptions: ChatRequestOptions,
        apiKey: String,
    ): String {
        val endpointPath = if (stream) {
            "/models/$modelID:streamGenerateContent"
        } else {
            "/models/$modelID:generateContent"
        }
        val path = versionedEndpointPath(
            baseUrl = baseUrl,
            requestOptions = requestOptions,
            defaultVersion = "v1beta",
            acceptedVersions = setOf("v1", "v1beta"),
            endpointPath = endpointPath,
        )
        val transport = RelayTransport.GeminiGenerateContent
        val relayRequested = requestOptions.relayRequested
        val authMode = resolveAuthMode(requestOptions, transport)
        return buildUrl(
            baseUrl = baseUrl,
            path = path,
            requestOptions = requestOptions,
            apiKey = apiKey.takeIf { authMode == RelayAuthMode.QueryKey },
            transport = transport,
            extraQuery = buildList {
                if (stream) add("alt" to "sse")
                if (authMode == RelayAuthMode.QueryKey) add("key" to apiKey)
                if (authMode != RelayAuthMode.None) {
                    relayRequested?.queryParams.orEmpty().forEach { add(it.key to it.value) }
                }
            },
        )
    }

    private fun buildAnthropicUrl(
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
        apiKey: String,
        transport: RelayTransport,
    ): String {
        return buildUrl(
            baseUrl = baseUrl,
            path = versionedEndpointPath(
                baseUrl = baseUrl,
                requestOptions = requestOptions,
                defaultVersion = "v1",
                acceptedVersions = setOf("v1"),
                endpointPath = "/messages",
            ),
            requestOptions = requestOptions,
            apiKey = apiKey,
            transport = transport,
        )
    }

    private fun versionedEndpointPath(
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
        defaultVersion: String,
        acceptedVersions: Set<String>,
        endpointPath: String,
    ): String {
        if (!requestOptions.relayRequested?.resolvedAPIBaseURL.isNullOrBlank()) return endpointPath
        val basePath = runCatching {
            java.net.URI(resolveUrl(baseUrl)).path.trimEnd('/')
        }.getOrDefault("")
        val alreadyVersioned = acceptedVersions.any { version ->
            basePath == "/$version" || basePath.endsWith("/$version")
        }
        return if (alreadyVersioned) endpointPath else "/$defaultVersion$endpointPath"
    }

    private fun buildUrl(
        baseUrl: String?,
        path: String,
        requestOptions: ChatRequestOptions? = null,
        apiKey: String? = null,
        transport: RelayTransport? = null,
        extraQuery: List<Pair<String, String>> = emptyList(),
    ): String {
        val base = resolveUrl(
            requestOptions?.relayRequested?.resolvedAPIBaseURL?.takeIf { it.isNotBlank() } ?: baseUrl,
        )
        val authMode = requestOptions?.let {
            resolveAuthMode(it, transport ?: RelayTransport.OpenAIChatCompletions)
        }
        val query = buildRelayQueryPairs(
            protocolQuery = extraQuery,
            requested = requestOptions?.relayRequested,
            authMode = authMode,
            apiKey = apiKey,
            includeCustomQuery = requestOptions != null && transport != RelayTransport.GeminiGenerateContent,
        )
        val queryString = query
            .filter { it.first.isNotBlank() }
            .joinToString("&") { "${it.first}=${java.net.URLEncoder.encode(it.second, StandardCharsets.UTF_8.name())}" }
        return buildString {
            append(base)
            append(path)
            if (queryString.isNotEmpty()) {
                append('?')
                append(queryString)
            }
        }
    }

    private suspend fun mapRelayHttpError(
        response: io.ktor.client.statement.HttpResponse,
        upstreamUrl: String,
        requestOptions: ChatRequestOptions,
        modelID: String?,
        relayKind: RelayKind? = null,
    ): ProviderServiceError {
        val transport = requestOptions.relayRequested?.transport
            ?.takeIf { it != RelayTransport.Auto }
            ?: RelayTransport.OpenAIChatCompletions
        val body = response.bodyAsText()
        return RelayErrorMapper.mapOrDefault(
            status = response.status.value,
            body = body,
            upstreamUrl = upstreamUrl,
            context = RelayErrorContext(
                relayKind = relayKind,
                transport = transport,
                authMode = resolveAuthMode(requestOptions, transport),
                modelID = modelID,
                codexCompatIdentity = requestOptions.relayRequested?.codexCompatIdentity,
            ),
            credentials = relayCredentialMaterial(response),
        )
    }

    /**
     * Extracts the cleartext credentials from the request that was actually sent, so the error
     * object is fully masked before it can reach any UI.
     */
    private fun relayCredentialMaterial(response: HttpResponse): List<String> {
        val namedValues = buildList {
            response.request.headers.entries().forEach { (name, values) ->
                values.forEach { value -> add(name to value) }
            }
            response.request.url.parameters.entries().forEach { (name, values) ->
                values.forEach { value -> add(name to value) }
            }
        }
        return RelayEndpointPolicy.credentialMaterial(namedValues)
    }

    private suspend inline fun <reified T> decodeRelaySuccessResponse(response: HttpResponse): T {
        val body = response.bodyAsText()
        return try {
            json.decodeFromString<T>(body)
        } catch (error: SerializationException) {
            // A schema decode failure on otherwise valid JSON may well be a client-side regression
            // worth surfacing, but the original exception message embeds the response body and
            // ChatRepository would persist it into the failed message, so only a fixed, safe
            // summary is propagated.
            if (runCatching { json.parseToJsonElement(body) }.isSuccess) {
                throw SerializationException(MALFORMED_SCHEMA_RESPONSE_DETAIL, error)
            }
            throw ProviderServiceError.RelayUpstream(
                statusCode = response.status.value,
                guidance = MALFORMED_SUCCESS_RESPONSE_GUIDANCE,
                // SerializationException.message embeds the raw response body, and the failure card
                // shows technicalDetail, so only a stable classification is kept here. HTML, the
                // prompt, or a credential echoed back by the upstream must not end up in the error.
                detail = "The custom LLM returned malformed JSON.",
            )
        }
    }

    private fun resolveTransport(requestOptions: ChatRequestOptions): RelayTransport {
        return requestOptions.relayRequested?.transport
            ?.takeIf { it != RelayTransport.Auto }
            ?: RelayTransport.OpenAIChatCompletions
    }

    /**
     * Builds the runtime cache identity only after the actual dispatch and the final URL are known.
     * If any part is missing this returns null, which confines [UnsupportedParamRetry] to this one
     * retry so that stale negative evidence is never reused across connections.
     */
    private fun runtimeSelfHealIdentity(
        requestOptions: ChatRequestOptions,
        modelId: String,
        effectiveTransport: RelayTransport,
        finalUrl: String,
    ): CapabilityEvidenceFacade.QueryIdentity? = CapabilityEvidenceProductionAdapter.dispatchIdentity(
        localIdentity = requestOptions.capabilityEvidenceIdentity,
        model = requestOptions.activeModel?.takeIf { it.id == modelId }
            ?: AIModel(id = modelId, name = modelId),
        effectiveTransport = effectiveTransport,
        finalUrl = finalUrl,
    )

    /**
     * Builds the request projection only once the transport dispatch and the final URL are both
     * settled. This is the last point at which a relay's capabilities are decided, so an auto or
     * merely requested transport, and a base URL that has not been through query handling yet,
     * must never feed into it.
     */
    private fun requestCapabilityProjection(
        requestOptions: ChatRequestOptions,
        modelId: String,
        effectiveTransport: RelayTransport,
        finalUrl: String,
        reasoningMode: ReasoningMode,
        messages: List<ChatMessage> = emptyList(),
        webSearchEnabled: Boolean = false,
        toolCallRequested: Boolean = false,
    ): CapabilityEvidenceProductionAdapter.Projection {
        val model = requestOptions.activeModel
            ?.takeIf { it.id == modelId }
            ?: AIModel(id = modelId, name = modelId)
        val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
            localIdentity = requestOptions.capabilityEvidenceIdentity,
            model = model,
            effectiveTransport = effectiveTransport,
            finalUrl = finalUrl,
        )
        val generationKeys = model.generationProfile?.parameters
            .orEmpty()
            .mapNotNull { it.id?.takeIf(String::isNotBlank) }
            .mapTo(linkedSetOf()) { "generation_parameter/$it" }
        val effectiveReasoning = effectiveRelayReasoningMode(requestOptions, reasoningMode)
        val keys = generationKeys.apply {
            add("generation_parameter/temperature")
            add("generation_parameter/max_tokens")
            add("generation_parameter/max_output_tokens")
            add("generation_parameter/n_predict")
            add("web_search")
            add("vision_input")
            add("tool_call")
            if (effectiveReasoning != ReasoningMode.Automatic) add("reasoning_level/${effectiveReasoning.rawValue}")
        }
        val explicitKeys = requestOptions.generationParameters?.values
            .orEmpty()
            .filterValues { it.state != ai.oriveo.community.core.model.GenerationOverrideState.Inherit }
            .keys
            .mapTo(linkedSetOf()) { "generation_parameter/$it" }
            .apply {
                if (requestOptions.temperature != null) add("generation_parameter/temperature")
                if (requestOptions.maxTokens != null) {
                    add("generation_parameter/max_tokens")
                    add("generation_parameter/max_output_tokens")
                }
                if (effectiveReasoning != ReasoningMode.Automatic) {
                    add("reasoning_level/${effectiveReasoning.rawValue}")
                }
                if (webSearchEnabled) add("web_search")
                if (messages.any { message ->
                        message.attachments.orEmpty().any { attachment -> attachment.kind == AttachmentKind.Image }
                    }
                ) add("vision_input")
                if (toolCallRequested) add("tool_call")
            }
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = requestOptions.relayRequested,
            identity = identity,
            keys = keys,
            explicitKeys = explicitKeys,
        )
    }

    /**
     * Resolves the citation-parsing context for a relay stream:
     * - the strategy is chosen from `relayRequested.transportKind` first, which is the wire kind
     *   string the user typed in custom mode (`openai_responses`, `anthropic_messages` and so on).
     *   When that override is absent or does not parse, fall back to the transport this request is
     *   actually using.
     * - the shape comes from looking `relayRequested.webSearchProfile` up in the catalog's profile
     *   table. A missing profile, because web search is off or nothing was configured, yields null
     *   and the strategy falls back to its built-in field paths.
     *
     * The caller runs `strategy.parseCitations(chunk, shape)` on every chunk inside the streaming
     * loop and emits [StreamEvent.Citations] whenever citations come back.
     */
    private data class RelayCitationContext(
        val strategy: TransportStrategy,
        val shape: StreamShape?,
    )

    private fun resolveCitationContext(
        requestOptions: ChatRequestOptions,
        fallbackTransport: RelayTransport,
        webSearchEnabled: Boolean,
    ): RelayCitationContext {
        val relayRequested = requestOptions.relayRequested
        val overrideStrategy = relayRequested?.transportKind
            ?.let { runCatching { transportRegistry.strategyForWireValue(it) }.getOrNull() }
        val strategy = overrideStrategy
            ?: transportRegistry.strategy(transportKindFor(fallbackTransport))
        val shape = if (webSearchEnabled) {
            StreamShape.fromMetadata(
                MetadataClient.webSearchStreamShape(relayRequested?.webSearchProfile)
            )
        } else null
        return RelayCitationContext(strategy, shape)
    }

    private fun transportKindFor(transport: RelayTransport): TransportKind = when (transport) {
        // Only used by the generic citation resolver; native completion has no citations.
        RelayTransport.LlamaCppNative -> TransportKind.OpenAIChat
        RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> TransportKind.OpenAIChat
        RelayTransport.OpenAIResponses -> TransportKind.OpenAIResponses
        RelayTransport.AnthropicMessages -> TransportKind.AnthropicMessages
        RelayTransport.GeminiGenerateContent -> TransportKind.GeminiGenerate
    }

    private suspend fun <T> withRelayOpenAIXHighFallback(
        @Suppress("UNUSED_PARAMETER") transport: RelayTransport,
        @Suppress("UNUSED_PARAMETER") requestOptions: ChatRequestOptions,
        @Suppress("UNUSED_PARAMETER") reasoningMode: ReasoningMode,
        block: suspend (String?) -> T,
    ): T = block(null)

    private suspend fun withRelayOpenAIXHighFallbackFlow(
        @Suppress("UNUSED_PARAMETER") transport: RelayTransport,
        @Suppress("UNUSED_PARAMETER") requestOptions: ChatRequestOptions,
        @Suppress("UNUSED_PARAMETER") reasoningMode: ReasoningMode,
        block: suspend (String?) -> Flow<StreamEvent>,
    ): Flow<StreamEvent> = block(null)

    private fun resolveRelayOpenAIXReasoningEffort(
        transport: RelayTransport,
        requestOptions: ChatRequestOptions,
        reasoningMode: ReasoningMode,
    ): String? {
        return when (transport) {
            RelayTransport.LlamaCppNative -> null
            RelayTransport.OpenAIResponses -> resolveResponsesReasoningEffort(requestOptions, reasoningMode)
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.Auto,
            -> resolveChatReasoningEffort(requestOptions, reasoningMode)
            RelayTransport.AnthropicMessages,
            RelayTransport.GeminiGenerateContent,
            -> null
        }
    }

    private fun shouldRetryRelayOpenAIXHigh(reasoningEffort: String?, statusCode: Int): Boolean {
        return reasoningEffort == RelayReasoningEffort.XHigh.value && statusCode in 400..499
    }

    private fun validateChatRequest(apiKey: String, modelID: String, requestOptions: ChatRequestOptions) {
        if (requestOptions.relayRequested.requiresCredential && !hasStoredCredential(apiKey)) {
            throw ProviderServiceError.InvalidConfiguration("Missing API key.")
        }
        if (modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing model identifier.")
    }

    private fun validateRelayPingApiKey(apiKey: String, authMode: RelayAuthMode) {
        if (authMode.requiresCredential && !hasStoredCredential(apiKey)) {
            throw ProviderServiceError.InvalidConfiguration("Missing API key.")
        }
    }

    private fun validateRelayPingModel(modelID: String) {
        if (modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing model identifier.")
    }

    private fun buildModels(
        remoteModels: List<RemoteModel>,
        preferredModelID: String?,
    ): List<AIModel> {
        val normalizedPreferred = preferredModelID?.trim()
        val models = remoteModels
            .filter { isChatModel(it.id) }
            .map { remote ->
                val baseModel = CatalogModelBuilder.buildCatalogModel(
                    providerKind = ProviderKind.Relay,
                    runtimeModelId = remote.id,
                    fallbackName = remote.id,
                    createdAt = remote.created,
                )
                val family = RelayFamilyHeuristics.infer(remote.id)
                val grouped = if (family != null) {
                    val (groupKey, groupName) = groupMetadata(family)
                    baseModel.copy(groupKey = groupKey, groupName = groupName)
                } else {
                    baseModel
                }
                if (normalizedPreferred == remote.id) grouped.copy(isDefault = true) else grouped
            }
            .sortedWith(compareBy<AIModel> { it.groupName.orEmpty() }.thenBy { it.name.lowercase() })

        if (normalizedPreferred != null && models.any { it.isDefault }) {
            return models
        }
        if (models.isEmpty()) return emptyList()
        val default = models.firstOrNull { it.isDefault } ?: models.first()
        return models.map { if (it.id == default.id) it.copy(isDefault = true) else it.copy(isDefault = false) }
    }

    private fun groupMetadata(family: RelayModelFamily): Pair<String, String> = when (family) {
        RelayModelFamily.OpenAI -> "openai" to "OpenAI"
        RelayModelFamily.Anthropic -> "anthropic" to "Anthropic"
        RelayModelFamily.Google -> "google" to "Google"
        RelayModelFamily.DeepSeek -> "deepseek" to "DeepSeek"
        RelayModelFamily.Qwen -> "qwen" to "Qwen"
        RelayModelFamily.XAI -> "x-ai" to "xAI"
        RelayModelFamily.Meta -> "meta" to "Meta"
        RelayModelFamily.Mistral -> "mistralai" to "Mistral"
    }

    private fun isChatModel(id: String): Boolean {
        val lowered = id.lowercase()
        // heuristic-allow: Relay model-list validation excludes image/audio embeddings; official providers use metadata.
        return EXCLUDED_PREFIXES.none { lowered.startsWith(it) }
    }

    private fun resolveUrl(custom: String?): String {
        val url = (custom?.takeIf { it.isNotBlank() } ?: "").trimEnd('/')
        return if (url.startsWith("http")) url else "https://$url"
    }

    private fun extractErrorMessage(body: String): String? {
        if (body.isBlank()) return null
        return runCatching {
            json.decodeFromString<ErrorEnvelope>(body).error?.message?.takeIf { it.isNotBlank() }
        }.getOrNull() ?: body.take(500).takeIf { it.isNotBlank() }
    }

    @Serializable
    private data class ModelsResponse(val data: List<RemoteModel> = emptyList())

    @Serializable
    private data class RemoteModel(val id: String, val created: Double? = null)

    @Serializable
    private data class ChatCompletionResponse(
        val choices: List<ChatChoice> = emptyList(),
        val usage: Usage? = null,
    )

    @Serializable
    private data class ChatChoice(val message: ChatChoiceMessage)

    @Serializable
    private data class ChatChoiceMessage(val content: String = "")

    @Serializable
    private data class StreamChunk(
        val choices: List<ChunkChoice>? = null,
        val usage: Usage? = null,
    )

    @Serializable
    private data class ChunkChoice(val delta: ChunkDelta? = null)

    @Serializable
    private data class ChunkDelta(
        val content: String? = null,
        val images: List<ChunkImage>? = null,
    )

    @Serializable
    private data class ChunkImage(val image_url: ChunkImageUrl? = null)

    @Serializable
    private data class ChunkImageUrl(val url: String? = null)

    @Serializable
    private data class Usage(
        val prompt_tokens: Int = 0,
        val completion_tokens: Int = 0,
        // An OpenAI-compatible upstream may pass cached_tokens / reasoning_tokens straight through.
        val prompt_tokens_details: UsagePromptDetails? = null,
        val completion_tokens_details: UsageCompletionDetails? = null,
    )

    @Serializable
    private data class UsagePromptDetails(val cached_tokens: Int? = null)

    @Serializable
    private data class UsageCompletionDetails(val reasoning_tokens: Int? = null)

    @Serializable
    private data class ResponsesResponse(
        val output_text: String? = null,
        val output: List<ResponseOutputItem>? = null,
        val usage: ResponsesUsage? = null,
    ) {
        val resolvedText: String
            get() {
                if (!output_text.isNullOrBlank()) return output_text
                return output
                    ?.flatMap { it.content ?: emptyList() }
                    ?.mapNotNull { if (it.type == "output_text") it.text else null }
                    ?.joinToString("")
                    .orEmpty()
            }

        val resolvedAttachments: List<Attachment>
            get() {
                val attachments = mutableListOf<Attachment>()
                fun imageAttachment(base64: String) = Attachment(
                    id = UUID.randomUUID().toString(),
                    kind = AttachmentKind.Image,
                    fileName = "generated_image.png",
                    mimeType = "image/png",
                    base64Data = base64,
                )
                output.orEmpty().forEach { item ->
                    if (item.type == "image_generation_call" && !item.result.isNullOrBlank()) {
                        attachments += imageAttachment(item.result)
                    }
                    item.content.orEmpty().forEach { part ->
                        if (part.type == "output_image" && !part.result.isNullOrBlank()) {
                            attachments += imageAttachment(part.result)
                        }
                    }
                }
                return attachments
            }
    }

    @Serializable
    private data class ResponseOutputItem(
        val type: String? = null,
        val content: List<ResponseOutputPart>? = null,
        val result: String? = null,
    )

    @Serializable
    private data class ResponseOutputPart(
        val type: String? = null,
        val text: String? = null,
        val result: String? = null,
    )

    @Serializable
    private data class ResponsesUsage(
        val input_tokens: Int? = null,
        val output_tokens: Int? = null,
        val input_tokens_details: ResponsesInputDetails? = null,
        val output_tokens_details: ResponsesOutputDetails? = null,
    )

    @Serializable
    private data class ResponsesInputDetails(val cached_tokens: Int? = null)

    @Serializable
    private data class ResponsesOutputDetails(val reasoning_tokens: Int? = null)

    @Serializable
    private data class ResponsesStreamDelta(val delta: String? = null)

    @Serializable
    private data class ResponsesStreamImageDone(
        val id: String? = null,
        val item_id: String? = null,
        val result: String? = null,
    )

    @Serializable
    private data class ResponsesStreamOutputItemDone(val item: ResponsesOutputItemDone? = null)

    @Serializable
    private data class ResponsesOutputItemDone(
        val id: String? = null,
        val type: String? = null,
        val result: String? = null,
    )

    @Serializable
    private data class ResponsesStreamCompleted(
        val usage: ResponsesUsage? = null,
        val response: ResponsesCompletedResponse? = null,
    ) {
        val resolvedUsage: ResponsesUsage?
            get() = usage ?: response?.usage
    }

    @Serializable
    private data class ResponsesCompletedResponse(val usage: ResponsesUsage? = null)

    @Serializable
    private data class AnthropicResponse(
        val content: List<AnthropicContent>? = null,
        val usage: AnthropicUsage? = null,
    ) {
        val resolvedText: String
            get() = content.orEmpty()
                .filter { it.type == "text" }
                .mapNotNull { it.text }
                .joinToString("")
    }

    @Serializable
    private data class AnthropicContent(
        val type: String? = null,
        val text: String? = null,
    )

    @Serializable
    private data class AnthropicUsage(
        val input_tokens: Int? = null,
        val output_tokens: Int? = null,
        val cache_read_input_tokens: Int? = null,
        val cache_creation_input_tokens: Int? = null,
        val cache_creation: AnthropicCacheCreation? = null,
    )

    @Serializable
    private data class AnthropicCacheCreation(
        val ephemeral_5m_input_tokens: Int? = null,
        val ephemeral_1h_input_tokens: Int? = null,
    )

    @Serializable
    private data class MessageStartEvent(val message: MessageStart? = null)

    @Serializable
    private data class MessageStart(val usage: InputUsage? = null)

    @Serializable
    private data class InputUsage(
        val input_tokens: Int = 0,
        val cache_read_input_tokens: Int? = null,
        val cache_creation_input_tokens: Int? = null,
        val cache_creation: AnthropicCacheCreation? = null,
    )

    @Serializable
    private data class ContentDeltaEvent(val delta: TextDelta? = null)

    /**
     * The polymorphic delta carried by an Anthropic content_block_delta event, mirroring
     * AnthropicService.AnyDelta:
     *  - type=text_delta: [text] carries a body token
     *  - type=thinking_delta: [thinking] carries an extended thinking token
     *  - anything else (signature_delta and friends) is ignored
     */
    @Serializable
    private data class TextDelta(
        val type: String? = null,
        val text: String? = null,
        val thinking: String? = null,
    )

    @Serializable
    private data class MessageDeltaEvent(val usage: OutputUsage? = null)

    @Serializable
    private data class OutputUsage(
        val output_tokens: Int = 0,
        val cache_read_input_tokens: Int? = null,
        val cache_creation_input_tokens: Int? = null,
        val cache_creation: AnthropicCacheCreation? = null,
    )

    @Serializable
    private data class GenerateResponse(
        val candidates: List<Candidate>? = null,
        val usageMetadata: UsageMeta? = null,
        val promptFeedback: PromptFeedback? = null,
    )

    @Serializable
    private data class Candidate(
        val content: CandidateContent? = null,
        val finishReason: String? = null,
    )

    @Serializable
    private data class PromptFeedback(val blockReason: String? = null)

    @Serializable
    private data class CandidateContent(val parts: List<Part>? = null)

    @Serializable
    private data class Part(
        val text: String? = null,
        val inlineData: InlineData? = null,
    )

    @Serializable
    private data class InlineData(
        val mimeType: String,
        val data: String,
    )

    @Serializable
    private data class UsageMeta(
        val promptTokenCount: Int? = null,
        val candidatesTokenCount: Int? = null,
        val thoughtsTokenCount: Int? = null,
        val cachedContentTokenCount: Int? = null,
    )

    @Serializable
    private data class ErrorEnvelope(val error: ErrorBody? = null)

    @Serializable
    private data class ErrorBody(val message: String? = null)
}
