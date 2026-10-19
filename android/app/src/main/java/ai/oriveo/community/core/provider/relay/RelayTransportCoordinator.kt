package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.context.StreamFinishTracker
import ai.oriveo.community.core.context.StopFamily
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.attachments.NativeFileFallback
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayGuidanceCode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ToolCallDelta
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.core.provider.LocalEngineRuntimeClient
import ai.oriveo.community.core.provider.LocalPromptPreflight
import ai.oriveo.community.core.provider.NativeToolCallAccumulator
import ai.oriveo.community.core.provider.NativeToolCallParser
import ai.oriveo.community.core.provider.NativeToolProtocol
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.CatalogModelBuilder
import ai.oriveo.community.core.provider.RelayErrorContext
import ai.oriveo.community.core.provider.RelayErrorMapper
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.RelayFamilyHeuristics
import ai.oriveo.community.core.provider.RelayRetryHints
import ai.oriveo.community.core.provider.RelayUpstreamErrorPayload
import ai.oriveo.community.core.provider.SseParser
import ai.oriveo.community.core.provider.UnsupportedParamRetry
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.UsageBreakdown
import ai.oriveo.community.core.provider.isRelayGenerationSuccessResponse
import ai.oriveo.community.core.provider.relay.RelayHeaderBuilder.applyRelayHeaders
import ai.oriveo.community.core.provider.relay.RelayHeaderBuilder.resolveAuthMode
import ai.oriveo.community.core.provider.sseLineReader
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
import io.ktor.utils.io.availableForRead
import io.ktor.utils.io.jvm.javaio.toInputStream
import io.ktor.utils.io.peek
import io.ktor.utils.io.readUTF8Line
import java.nio.charset.StandardCharsets
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
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
 *   - relay models are not in the catalog, so the profile streamShape is inferred from the web
 *     fragment merged into this turn and looked up through [MetadataClient.webSearchStreamShape]
 *   - `relayRequested.transportKind` and `relayRequested.transport` together decide which strategy
 *     is selected
 */
internal class RelayTransportCoordinator(
    client: HttpClient,
    private val json: Json,
    private val transportRegistry: TransportRegistry,
    /** Negative cache of the upstream-rejection loop: on the relay form the native-file fallback records `file` here. */
    private val negativeCache: RelayNegativeCache = RelayNegativeCache.shared,
    /** Candidates for protocol fallback (same rules as the per-model probe); evaluated only after a route-level rejection before any output. */
    private val protocolCandidates: suspend (requestOptions: ChatRequestOptions, modelID: String, baseUrl: String?) -> List<RelayTransport> =
        { options, modelID, baseUrl ->
            RelayProbeCandidates.candidates(
                RelayCatalogEndpointTypes.lookup(RelayCatalogEndpointTypes.catalogRoot(options.relayRequested, baseUrl), modelID),
                modelID,
            ) { ai.oriveo.community.core.data.remote.RelayModelFamilyLookup.shared.family(it) }
        },
) : ProviderService,
    RelayOpenAIResponsesTransport.Delegate,
    RelayOpenAIChatTransport.Delegate,
    RelayAnthropicMessagesTransport.Delegate,
    RelayGeminiTransport.Delegate {

    private val client = client.config { install(relayLocalSecurityPlugin()) }
    private val localRuntimeClient = LocalEngineRuntimeClient(this.client, json)

    companion object {
        /** Output cap of the probe (`probeRequestRules`): Responses uses the official floor of 16, the other protocols 1. */
        internal const val PROBE_RESPONSES_MAX_OUTPUT_TOKENS = 16
        internal const val PROBE_MAX_TOKENS = 1

        /** Display order after a catalog refresh is decoded (group, then name); applied again after multi-key merging, in the same order as the single-key path. */
        val CATALOG_ORDER: Comparator<AIModel> = compareBy<AIModel> { it.groupName.orEmpty() }.thenBy { it.name.lowercase() }

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

        /** The three protocols that have native file block lanes, matching [nativeFileLane] one to one. */
        private val NATIVE_FILE_TRANSPORTS = setOf(
            RelayTransport.OpenAIResponses,
            RelayTransport.AnthropicMessages,
            RelayTransport.GeminiGenerateContent,
        )

        private const val MALFORMED_SUCCESS_RESPONSE_GUIDANCE =
            "The provider returned an error for this request. Please retry or switch models."
        /** Word for word the English of `R.string.relay_guidance_web_page_returned` (the display layer takes the resource by guidanceCode). */
        private const val WEB_PAGE_RETURNED_GUIDANCE =
            "This connection returned a web page instead of a model response. Check the request URL and the protocol set for this model."
        /** If a stream body still shows no content after this many leading whitespace bytes, stop waiting and treat it as a normal stream. */
        private const val STREAM_PAGE_SNIFF_MAX_BYTES = 4096
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
                transportKnown = false,
            )
        }

        val parsed = decodeRelaySuccessResponse<ModelsResponse>(response)
        val models = buildModels(parsed.data, preferredModelID)
        if (models.isEmpty()) throw ProviderServiceError.EmptyModelCatalog
        return ProviderSyncResult(models = models, relayEndpointTypes = endpointTypes(parsed.data))
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
                transportKnown = false,
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
        val routed = routed(requestOptions, baseUrl)
        val request = RelayTransportRequest(
            apiKey = apiKey,
            modelID = modelID,
            messages = messages,
            baseUrl = baseUrl,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = routed,
        )
        val current = resolveTransport(routed)
        try {
            return dispatchSendDroppingRejectedWeb(request)
        } catch (error: ProviderServiceError) {
            val next = nextProtocol(request, current, error, outputStarted = false) ?: throw error
            request.requestOptions.relayProtocolSwitchStarted?.invoke(next)
            // The failure reports the second attempt's error, so the second attempt throws straight out.
            val done = dispatchSendDroppingRejectedWeb(request.switchedTo(next))
            request.requestOptions.relayProtocolSwitched?.invoke(next)
            return done
        }
    }

    /**
     * Resend without the web fragment when it is rejected (fixture `web-probe.v1.json` chatCases): this attempt carried the web fragment of its protocol and received
     * 400 / 422 before any output, and the rejection is neither route-level (that goes to protocol fallback) nor model_access_denied (never resent)
     * -> resend once on the same protocol without the fragment. A successful resend calls back [ChatRequestOptions.relayWebFragmentDropped]; if the resend also fails, the original error is reported.
     */
    private fun webFragmentRetry(
        request: RelayTransportRequest,
        error: ProviderServiceError,
        outputStarted: Boolean,
    ): RelayTransportRequest? {
        if (outputStarted) return null
        val transport = resolveTransport(request.requestOptions)
        if (request.requestOptions.relayWebFragments[transport.value] == null) return null
        if (RelayKeyAccess.isModelAccessDenied(error) || RelayProtocolFallback.isRouteRejection(error)) return null
        val status = when (error) {
            is ProviderServiceError.Upstream -> error.statusCode.takeUnless { error.streamErrorFrame }
            is ProviderServiceError.RelayUpstream -> error.statusCode
            else -> null
        } ?: return null
        if (status != 400 && status != 422) return null
        return request.copy(
            webSearchEnabled = false,
            requestOptions = request.requestOptions.copy(
                relayWebFragments = request.requestOptions.relayWebFragments - transport.value,
            ),
        )
    }

    private suspend fun dispatchSendDroppingRejectedWeb(request: RelayTransportRequest): StreamEvent.Done =
        try {
            dispatchSend(request)
        } catch (error: ProviderServiceError) {
            val retry = webFragmentRetry(request, error, outputStarted = false) ?: throw error
            val done = try {
                dispatchSend(retry)
            } catch (_: ProviderServiceError) {
                throw error
            }
            request.requestOptions.relayWebFragmentDropped?.invoke(resolveTransport(request.requestOptions))
            done
        }

    private fun dispatchStreamDroppingRejectedWeb(request: RelayTransportRequest): Flow<StreamEvent> = flow {
        var emitted = false
        try {
            dispatchStream(request).collect {
                emitted = true
                emit(it)
            }
        } catch (error: ProviderServiceError) {
            val retry = webFragmentRetry(request, error, outputStarted = emitted) ?: throw error
            var retryEmitted = false
            try {
                dispatchStream(retry).collect {
                    retryEmitted = true
                    emit(it)
                }
            } catch (retryError: ProviderServiceError) {
                throw if (retryEmitted) retryError else error
            }
            request.requestOptions.relayWebFragmentDropped?.invoke(resolveTransport(request.requestOptions))
        }
    }

    /**
     * Reasoning-tier rejection loop (fixture `reasoning-tier.v1.json`): before sending, land on the nearest tier by the negative cache; if a tier was sent and
     * the upstream answers 400 / 422 before any output with a body naming the thinking parameter, record `reasoningTier:<tier>` (connection x model x effective
     * protocol, 7 days) and resend once with the nearest tier; if the resend also fails, report the original error.
     */
    private suspend fun dispatchSend(request: RelayTransportRequest): StreamEvent.Done {
        val landed = landedOnRejectedTier(request)
        return try {
            dispatchSendOnce(landed)
        } catch (error: ProviderServiceError) {
            val retry = tierRetry(landed, error, outputStarted = false) ?: throw error
            try {
                dispatchSendOnce(retry)
            } catch (_: ProviderServiceError) {
                throw error
            }
        }
    }

    private fun dispatchStream(request: RelayTransportRequest): Flow<StreamEvent> = flow {
        val landed = landedOnRejectedTier(request)
        var emitted = false
        try {
            dispatchStreamOnce(landed).collect {
                emitted = true
                emit(it)
            }
        } catch (error: ProviderServiceError) {
            val retry = tierRetry(landed, error, outputStarted = emitted) ?: throw error
            var retryEmitted = false
            try {
                dispatchStreamOnce(retry).collect {
                    retryEmitted = true
                    emit(it)
                }
            } catch (retryError: ProviderServiceError) {
                throw if (retryEmitted) retryError else error
            }
        }
    }

    /**
     * The tier this chat turn selected and really sent; null for automatic. The connection-level tier is void and no longer read.
     */
    private fun sentTier(request: RelayTransportRequest): String? {
        if (resolveTransport(request.requestOptions) == RelayTransport.LlamaCppNative) return null
        return request.reasoningMode.takeIf { it != ReasoningMode.Automatic }?.rawValue
    }

    /** Same value as the read side [RelayNegativeCache.keyFor]: connection = provider.id, model = the model id in storage, protocol = the effective protocol. */
    private fun tierKey(request: RelayTransportRequest): RelayNegativeCache.Key? {
        val connectionId = request.requestOptions.modelControlRuntimeIdentity?.connectionId
            ?: request.requestOptions.capabilityEvidenceIdentity?.connectionInstanceId
            ?: return null
        val transport = resolveTransport(request.requestOptions)
            .takeUnless { it == RelayTransport.Auto } ?: RelayTransport.OpenAIChatCompletions
        return RelayNegativeCache.Key(connectionId, request.requestOptions.activeModel?.id ?: request.modelID, transport.value)
    }

    /** The tiers that can be landed on = the same available set as the panel: the automatic set (model-facts) intersected with the model-level override; when empty the fallback is null (no thinking field is sent). */
    private fun availableTiers(request: RelayTransportRequest): List<String> {
        val model = request.requestOptions.activeModel ?: AIModel(id = request.modelID, name = request.modelID)
        val provider = ai.oriveo.community.core.model.Provider(
            id = request.requestOptions.capabilityEvidenceIdentity?.connectionInstanceId ?: "runtime-relay",
            kind = ProviderKind.Relay,
            relayRequested = request.requestOptions.relayRequested,
        )
        val automatic = RelayReasoningTiers.automaticTiers(provider, model).map { it.rawValue }
        val levels = model.relayCapabilityOverrides?.reasoningLevels ?: return automatic
        return automatic.filter { it in levels }
    }

    /** Switch to the [target] tier (null = send no thinking field). It is reached only when there is no connection-level effort, which is not rewritten. */
    private fun RelayTransportRequest.withTier(target: String?): RelayTransportRequest = copy(
        reasoningMode = target?.let(RelayReasoningTiers::mode) ?: ReasoningMode.Automatic,
    )

    private fun landedOnRejectedTier(request: RelayTransportRequest): RelayTransportRequest {
        val sent = sentTier(request) ?: return request
        val rejected = tierKey(request)?.let(negativeCache::rejectedReasoningTiers).orEmpty()
        if (sent !in rejected) return request
        return request.withTier(RelayReasoningTiers.fallback(availableTiers(request), rejected, sent))
    }

    private fun tierRetry(request: RelayTransportRequest, error: ProviderServiceError, outputStarted: Boolean): RelayTransportRequest? {
        val sent = sentTier(request) ?: return null
        val status = when (error) {
            is ProviderServiceError.Upstream -> error.statusCode.takeUnless { error.streamErrorFrame }
            is ProviderServiceError.RelayUpstream -> error.statusCode
            else -> null
        } ?: return null
        val rejectedTier = RelayReasoningTiers.classify(status, error.relayBodyNamesThinking, sent, outputStarted) ?: return null
        val key = tierKey(request)
        if (key != null) RelayNegativeCache.Kind.reasoningTier(rejectedTier)?.let { negativeCache.record(key, it) }
        val rejected = key?.let(negativeCache::rejectedReasoningTiers).orEmpty() + rejectedTier
        return request.withTier(RelayReasoningTiers.fallback(availableTiers(request), rejected, sent))
    }

    private suspend fun dispatchSendOnce(request: RelayTransportRequest): StreamEvent.Done =
        when (resolveTransport(request.requestOptions)) {
            RelayTransport.LlamaCppNative -> sendLlamaCppNative(request)
            RelayTransport.OpenAIResponses ->
                sendWithNativeFileFallback(request, RelayTransport.OpenAIResponses, openAIResponsesTransport::send)
            RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> openAIChatTransport.send(request)
            RelayTransport.GeminiGenerateContent ->
                sendWithNativeFileFallback(request, RelayTransport.GeminiGenerateContent, geminiTransport::send)
            RelayTransport.AnthropicMessages ->
                sendWithNativeFileFallback(request, RelayTransport.AnthropicMessages, anthropicMessagesTransport::send)
        }

    /**
     * Protocol-level fallback: wrapped outside the native-file fallback; the inner layer first falls back to text on the original protocol, and only if the failure is still a route-level rejection does it get here.
     * The local engine's native protocol does not take part.
     */
    private suspend fun nextProtocol(
        request: RelayTransportRequest,
        current: RelayTransport,
        error: ProviderServiceError,
        outputStarted: Boolean,
    ): RelayTransport? {
        if (current == RelayTransport.LlamaCppNative) return null
        // No access is a matter of key and model; switching protocol would be refused just the same.
        if (RelayKeyAccess.isModelAccessDenied(error)) return null
        // Same criterion as the per-model probe.
        val routeRejected = RelayProtocolFallback.isRouteRejection(error)
        val model = request.requestOptions.activeModel
        // A model without its own protocol follows the connection, and its source is treated as null.
        val source = model?.relayTransportSource?.takeIf {
            model.relayTransport != null && model.relayTransport != RelayTransport.Auto
        }
        // Looking up candidates may fetch the by-model view, so check the criterion first.
        if (!RelayProtocolFallback.mayFallBack(source, routeRejected, outputStarted, alreadySwitched = false)) return null
        // The connection protocol the user picked has top priority: a model that follows the connection has no other candidates, so the protocol is not switched.
        if (source == null && RelayProbeCandidates.connectionIsExplicit(request.requestOptions.relayRequested)) return null
        val candidates = protocolCandidates(request.requestOptions, request.modelID, request.baseUrl)
        val next = RelayProtocolFallback.nextTransport(current, source, candidates, routeRejected, outputStarted, alreadySwitched = false)
            ?: return null
        // The body to switch to is recomputed by the new protocol's builder under the new protocol's delivery decision; if the target protocol does not accept native files
        // and the files currently routed as native have not a single one with text, there is nothing to send after switching, so do not switch and report the original error.
        val targetSendsNativeFiles = next in NATIVE_FILE_TRANSPORTS && nativeFileLane(next).first.allowsNativeFiles
        if (!targetSendsNativeFiles && current in NATIVE_FILE_TRANSPORTS && hasOnlyUnrecoverableNativeFiles(request, current)) {
            return null
        }
        return next
    }

    private fun RelayTransportRequest.switchedTo(transport: RelayTransport): RelayTransportRequest {
        val probeModel = (requestOptions.activeModel ?: AIModel(id = modelID, name = modelID)).copy(relayTransport = transport)
        return copy(
            // A relay chat's "web this round" follows whether this attempt carries the target protocol's fragment; callers that injected no fragments keep their original intent.
            webSearchEnabled = requestOptions.relayWebFragments.takeIf { it.isNotEmpty() }
                ?.let { it[transport.value] != null }
                ?: webSearchEnabled,
            requestOptions = requestOptions.copy(
                relayRouteTransport = transport,
                relayRouteAPIRoot = RelayEndpointResolver.effectiveAPIRoot(requestOptions.relayRequested, baseUrl, probeModel),
                activeModel = requestOptions.activeModel?.copy(relayTransport = transport),
            ),
        )
    }

    /**
     * The attachment transport of each of the three Relay protocols that carry native file blocks, paired with the official catalog entry used to look up the model allowlist.
     * It is the same pair [buildResponsesBody] / [buildAnthropicBody] / [buildGeminiBody] use.
     */
    private fun nativeFileLane(transport: RelayTransport): Pair<AttachmentTransportProfile, ProviderKind> =
        when (transport) {
            RelayTransport.OpenAIResponses -> AttachmentTransportProfile.RelayOpenAIResponses to ProviderKind.OpenAI
            RelayTransport.AnthropicMessages -> AttachmentTransportProfile.RelayAnthropicMessages to ProviderKind.Anthropic
            RelayTransport.GeminiGenerateContent -> AttachmentTransportProfile.RelayGeminiGenerateContent to ProviderKind.Gemini
            else -> error("no native file blocks on $transport")
        }

    private fun fallbackLane(request: RelayTransportRequest, transport: RelayTransport) = NativeFileFallback.Lane(
        // The connection identity comes first; callers without one (connectivity probes and the like) fall back to the endpoint address.
        connectionId = request.requestOptions.modelControlRuntimeIdentity?.connectionId
            ?: request.baseUrl.orEmpty(),
        providerKind = ProviderKind.Relay,
        protocol = transport.value,
    )

    private fun hasOnlyUnrecoverableNativeFiles(request: RelayTransportRequest, transport: RelayTransport): Boolean {
        val (profile, catalogKind) = nativeFileLane(transport)
        return NativeFileFallback.hasOnlyUnrecoverableNativeFiles(
            request.messages,
            relayRouterModel(request.modelID, catalogKind, request.requestOptions.activeModel),
            profile,
        )
    }

    private fun hasRecoverableNativeFile(request: RelayTransportRequest, transport: RelayTransport): Boolean {
        val (profile, catalogKind) = nativeFileLane(transport)
        return NativeFileFallback.hasRecoverableNativeFile(
            request.messages,
            relayRouterModel(request.modelID, catalogKind, request.requestOptions.activeModel),
            profile,
        )
    }

    private fun RelayTransportRequest.textOnly(textOnly: Boolean): RelayTransportRequest =
        if (textOnly) copy(requestOptions = requestOptions.copy(nativeFilesDisabled = true)) else this

    /**
     * When there is a connection identity, the native-file fallback records `file` in the negative cache, with the same key as the read side [RelayNegativeCache.keyFor]:
     * connection = provider.id, model = the model id in storage (activeModel, and only if missing the id sent upstream), protocol = this time's effective protocol.
     * Without an identity (connectivity probes and the like) the in-process memory is used as before.
     */
    private fun relayFileMemory(request: RelayTransportRequest, transport: RelayTransport): NativeFileFallback.RelayMemory? {
        val connectionId = request.requestOptions.modelControlRuntimeIdentity?.connectionId
            ?: request.requestOptions.capabilityEvidenceIdentity?.connectionInstanceId
            ?: return null
        return NativeFileFallback.RelayMemory(
            negativeCache,
            RelayNegativeCache.Key(connectionId, request.requestOptions.activeModel?.id ?: request.modelID, transport.value),
            fileOverride = request.requestOptions.activeModel?.relayCapabilityOverrides?.file,
        )
    }

    private suspend fun sendWithNativeFileFallback(
        request: RelayTransportRequest,
        transport: RelayTransport,
        send: suspend (RelayTransportRequest) -> StreamEvent.Done,
    ): StreamEvent.Done = NativeFileFallback.run(
        lane = fallbackLane(request, transport),
        recoverable = { hasRecoverableNativeFile(request, transport) },
        relayMemory = relayFileMemory(request, transport),
        onUnrecovered = { first -> reportFileRejected(request, transport, first) },
    ) { textOnly -> send(request.textOnly(textOnly)) }

    private fun streamWithNativeFileFallback(
        request: RelayTransportRequest,
        transport: RelayTransport,
        stream: (RelayTransportRequest) -> Flow<StreamEvent>,
    ): Flow<StreamEvent> = NativeFileFallback.stream(
        lane = fallbackLane(request, transport),
        recoverable = { hasRecoverableNativeFile(request, transport) },
        relayMemory = relayFileMemory(request, transport),
        onUnrecovered = { first -> reportFileRejected(request, transport, first) },
    ) { textOnly -> stream(request.textOnly(textOnly)) }

    /**
     * File-rejected hint card: the first attempt was a rejection signal (400 / 404 / 415 / 422 before any output; 413 does not count) and it really did carry native file blocks;
     * when the fallback did not recover, notify the sender to set the flag. The error shown is unchanged.
     */
    private fun reportFileRejected(request: RelayTransportRequest, transport: RelayTransport, first: ProviderServiceError) {
        if (!RelayNegativeCache.isRejectionSignal(first)) return
        if (!hasRecoverableNativeFile(request, transport) && !hasOnlyUnrecoverableNativeFiles(request, transport)) return
        request.requestOptions.relayFileRejected?.invoke()
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
        val routed = routed(requestOptions, baseUrl)
        val request = RelayTransportRequest(
            apiKey = apiKey,
            modelID = modelID,
            messages = messages,
            baseUrl = baseUrl,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = routed,
        )
        val current = resolveTransport(routed)
        return flow {
            var emitted = false
            try {
                dispatchStreamDroppingRejectedWeb(request).collect {
                    emitted = true
                    emit(it)
                }
                return@flow
            } catch (error: ProviderServiceError) {
                val next = nextProtocol(request, current, error, outputStarted = emitted) ?: throw error
                request.requestOptions.relayProtocolSwitchStarted?.invoke(next)
                emitAll(dispatchStreamDroppingRejectedWeb(request.switchedTo(next)))
                request.requestOptions.relayProtocolSwitched?.invoke(next)
            }
        }
    }

    private fun dispatchStreamOnce(request: RelayTransportRequest): Flow<StreamEvent> =
        when (resolveTransport(request.requestOptions)) {
            RelayTransport.LlamaCppNative -> streamLlamaCppNative(request)
            RelayTransport.OpenAIResponses ->
                streamWithNativeFileFallback(request, RelayTransport.OpenAIResponses, openAIResponsesTransport::stream)
            RelayTransport.AnthropicMessages ->
                streamWithNativeFileFallback(request, RelayTransport.AnthropicMessages, anthropicMessagesTransport::stream)
            RelayTransport.GeminiGenerateContent ->
                streamWithNativeFileFallback(request, RelayTransport.GeminiGenerateContent, geminiTransport::stream)
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.Auto,
            -> openAIChatTransport.stream(request)
        }

    suspend fun pingRelay(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        relayKind: RelayKind? = null,
        modelTransport: RelayTransport? = null,
    ) {
        validateRelayPingApiKey(apiKey, relayRequested.authMode)
        val (transport, requestOptions) = relayPingRoute(baseUrl, modelID, relayRequested, modelTransport)

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
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.Auto,
            -> if (modelID.isBlank()) {
                val upstreamUrl = buildUrl(baseUrl, "/models", requestOptions, apiKey, RelayTransport.OpenAIChatCompletions)
                val response = client.get(upstreamUrl) {
                    applyRelayHeaders(apiKey, requestOptions, RelayTransport.OpenAIChatCompletions)
                }
                requireSuccessfulRelayPing(response, upstreamUrl, requestOptions, null, relayKind)
            } else {
                sendRelayPing(apiKey, baseUrl, modelID, requestOptions, relayKind)
            }
            RelayTransport.OpenAIResponses,
            RelayTransport.AnthropicMessages,
            RelayTransport.GeminiGenerateContent,
            -> sendRelayPing(apiKey, baseUrl, modelID, requestOptions, relayKind)
        }
    }

    /**
     * The protocol and root go through the same resolver as a real send: [modelTransport] is the candidate protocol of the per-model probe
     * (null = follow the connection default), and the root is taken as if the model protocol were temporarily set to that candidate.
     */
    private fun relayPingRoute(
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        modelTransport: RelayTransport?,
    ): Pair<RelayTransport, ChatRequestOptions> {
        val probeModel = AIModel(id = modelID, name = modelID, relayTransport = modelTransport)
        val transport = RelayEndpointResolver.effectiveTransport(relayRequested, probeModel)
        return transport to ChatRequestOptions(
            relayRequested = relayRequested.copy(transport = transport),
            relayRouteTransport = transport,
            relayRouteAPIRoot = RelayEndpointResolver.effectiveAPIRoot(relayRequested, baseUrl, probeModel),
        )
    }

    private suspend fun sendRelayPing(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        requestOptions: ChatRequestOptions,
        relayKind: RelayKind?,
    ) {
        validateRelayPingModel(modelID)
        val wire = buildRelayProbeWireRequest(apiKey, modelID, baseUrl, requestOptions)
        val response = client.preparePost(wire.url) {
            applyRelayHeaders(apiKey, requestOptions, wire.transport)
            contentType(ContentType.Application.Json)
            setBody(wire.body)
        }.execute()
        requireSuccessfulRelayPing(response, wire.url, requestOptions, modelID, relayKind)
    }

    /**
     * The 1-token probe request of the four generation protocols (`probeRequestRules`): it is the chat request [buildRelayChatRequest] produces,
     * with the conversation replaced by a single ping, no streaming, an output cap of 1 (the official floor of 16 for Responses), and no tools. Identity / storage / cache fields and
     * headers ([applyRelayHeaders]) are the same as a chat send, so a gateway that validates the client shape sees the same shape.
     */
    private fun buildRelayProbeWireRequest(
        apiKey: String,
        modelID: String,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
    ): RelayChatWireRequest = buildRelayChatRequest(
        apiKey = apiKey,
        modelID = modelID,
        messages = listOf(
            ChatMessage(
                id = "relay-probe",
                role = ChatRole.User,
                text = "ping",
                providerKind = ProviderKind.Relay,
                providerName = "",
                modelID = modelID,
                modelName = modelID,
                state = ChatMessageState.Delivered,
            ),
        ),
        baseUrl = baseUrl,
        reasoningMode = ReasoningMode.Automatic,
        requestOptions = requestOptions,
        extras = RelayChatBuildExtras(
            maxOutputTokens = if (resolveTransport(requestOptions) == RelayTransport.OpenAIResponses) {
                PROBE_RESPONSES_MAX_OUTPUT_TOKENS
            } else {
                PROBE_MAX_TOKENS
            },
        ),
        stream = false,
        removeTools = true,
    )

    /** The effective protocol, URL and body of this per-model probe (the same one [pingRelay] sends), without sending a request. */
    internal fun buildRelayProbeRequest(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        modelTransport: RelayTransport? = null,
    ): RelayChatWireRequest =
        buildRelayProbeWireRequest(apiKey, modelID, baseUrl, relayPingRoute(baseUrl, modelID, relayRequested, modelTransport).second)

    /**
     * The URL and body of this ordinary streaming chat send: the protocol, API root, URL, capability projection and the four body builders
     * are all the same set as in stream*; [extras] is passed only by "test capability". Headers are added at send time by [applyRelayHeaders].
     */
    internal fun buildRelayChatStreamRequest(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        extras: RelayChatBuildExtras = RelayChatBuildExtras.None,
    ): RelayChatWireRequest =
        buildRelayChatRequest(apiKey, modelID, messages, baseUrl, reasoningMode, requestOptions, extras, stream = true, removeTools = false)

    /**
     * The one builder shared by [buildRelayChatStreamRequest] and the per-model probe. [stream] = false and [removeTools] = true
     * are passed only by the probe: no streaming, and Responses carries no default image_generation tool.
     */
    private fun buildRelayChatRequest(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        extras: RelayChatBuildExtras,
        stream: Boolean,
        removeTools: Boolean,
    ): RelayChatWireRequest {
        val routed = routed(requestOptions, baseUrl)
        val transport = resolveTransport(routed)
        fun projection(url: String) = requestCapabilityProjection(routed, modelID, transport, url, reasoningMode, messages)
        return when (transport) {
            RelayTransport.OpenAIChatCompletions -> {
                val url = buildUrl(baseUrl, "/chat/completions", routed, apiKey, transport)
                RelayChatWireRequest(
                    transport, url,
                    buildOpenAIChatBody(modelID, messages, stream, reasoningMode, routed, capabilityProjection = projection(url), extras = extras),
                )
            }
            RelayTransport.OpenAIResponses -> {
                val url = buildUrl(baseUrl, "/responses", routed, apiKey, transport)
                RelayChatWireRequest(
                    transport, url,
                    buildResponsesBody(
                        modelID, messages, stream, false, reasoningMode, false, routed,
                        removeTools = removeTools, capabilityProjection = projection(url), extras = extras,
                    ),
                )
            }
            RelayTransport.AnthropicMessages -> {
                val url = buildAnthropicUrl(baseUrl, routed, apiKey, transport)
                RelayChatWireRequest(
                    transport, url,
                    buildAnthropicBody(modelID, messages, stream, reasoningMode, routed, projection(url), buildExtras = extras),
                )
            }
            RelayTransport.GeminiGenerateContent -> {
                val url = buildGeminiUrl(baseUrl, modelID, stream, routed, apiKey)
                RelayChatWireRequest(
                    transport, url,
                    buildGeminiBody(messages, modelID, false, reasoningMode, false, routed, projection(url), extras = extras),
                )
            }
            RelayTransport.LlamaCppNative,
            RelayTransport.Auto,
            -> throw ProviderServiceError.InvalidConfiguration("Capability test does not support ${transport.value}.")
        }
    }

    /**
     * One item of "test capability": built by [buildRelayChatStreamRequest], with the same client and the same headers as chat,
     * sent exactly once (no fallback, no self-healing, no retry, no negative cache write); any HTTP status is read in full and handed back as is for judging.
     * The overall deadline is wrapped around the whole call by the caller (including reading the body); construction failures and network errors are thrown as usual.
     */
    suspend fun sendRelayCapabilityTest(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
        extras: RelayChatBuildExtras,
    ): RelayCapabilityTestResponse {
        validateChatRequest(apiKey, modelID, requestOptions)
        // Test capability carries no connection-level web fragment.
        val routed = routed(requestOptions, baseUrl).copy(relayWebFragments = emptyMap())
        val wire = buildRelayChatStreamRequest(apiKey, modelID, messages, baseUrl, ReasoningMode.Automatic, routed, extras)
        return client.preparePost(wire.url) {
            applyRelayHeaders(apiKey, routed, wire.transport)
            contentType(ContentType.Application.Json)
            setBody(wire.body)
        }.execute { response ->
            val status = response.status.value
            val contentType = response.contentType()?.toString()
            val body = response.bodyAsText()
            RelayCapabilityTestResponse.Http(
                status = status,
                contentType = contentType,
                body = body,
                evidence = if (status in 200..299) {
                    relayCapabilityTestEvidence(wire.transport, body, contentType)
                } else {
                    RelayCapabilityTestEvidence.None
                },
            )
        }
    }

    /**
     * The evidence step of test capability: feed the 2xx response, event by event, to the same parsing this protocol's chat uses --
     * function calls go through [NativeToolCallParser] + [NativeToolCallAccumulator], and visible text goes through the same DTOs as the chat stream
     * (Anthropic thinking_delta does not count as visible text). A non-SSE 2xx is treated as a single event as a whole.
     */
    private fun relayCapabilityTestEvidence(transport: RelayTransport, body: String, contentType: String?): RelayCapabilityTestEvidence {
        val protocol = when (transport) {
            RelayTransport.OpenAIChatCompletions -> NativeToolProtocol.OpenAIChat
            RelayTransport.OpenAIResponses -> NativeToolProtocol.OpenAIResponses
            RelayTransport.AnthropicMessages -> NativeToolProtocol.AnthropicMessages
            RelayTransport.GeminiGenerateContent -> NativeToolProtocol.GeminiGenerate
            RelayTransport.LlamaCppNative, RelayTransport.Auto -> return RelayCapabilityTestEvidence.None
        }
        val events = mutableListOf<Pair<String?, String>>()
        if (contentType.orEmpty().lowercase().contains("text/event-stream")) {
            var eventType: String? = null
            body.lineSequence().map { it.trimEnd('\r') }.forEach { line ->
                when {
                    line.isEmpty() -> eventType = null
                    line.startsWith("event:") -> eventType = line.removePrefix("event:").trim()
                    line.startsWith("data:") -> line.removePrefix("data:").trim()
                        .takeIf { it.isNotEmpty() && it != "[DONE]" }
                        ?.let { events += eventType to it }
                }
            }
        } else {
            events += null to body
        }
        val parser = NativeToolCallParser(protocol)
        val calls = mutableMapOf<Int, ToolCallDelta>()
        val text = StringBuilder()
        events.forEach { (declaredType, payload) ->
            val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull() ?: return@forEach
            val eventType = declaredType ?: (root["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            NativeToolCallAccumulator.merge(calls, parser.parse(eventType, root))
            val visible = runCatching {
                when (protocol) {
                    NativeToolProtocol.OpenAIChat -> json.decodeFromString<StreamChunk>(payload).choices?.firstOrNull()?.delta?.content
                    NativeToolProtocol.OpenAIResponses -> if (eventType == "response.output_text.delta") {
                        json.decodeFromString<ResponsesStreamDelta>(payload).delta
                    } else {
                        null
                    }
                    NativeToolProtocol.AnthropicMessages -> if (eventType == "content_block_delta") {
                        json.decodeFromString<ContentDeltaEvent>(payload).delta?.takeIf { it.type != "thinking_delta" }?.text
                    } else {
                        null
                    }
                    NativeToolProtocol.GeminiGenerate -> json.decodeFromString<GenerateResponse>(payload)
                        // A part with thought == true is a thinking summary and does not count as visible text.
                        .candidates?.firstOrNull()?.content?.parts.orEmpty().filter { it.thought != true }.mapNotNull { it.text }.joinToString("")
                }
            }.getOrNull()
            visible?.let(text::append)
        }
        return RelayCapabilityTestEvidence(
            visibleText = text.toString(),
            functionCallNames = calls.toSortedMap().values.mapNotNull { it.name?.takeIf(String::isNotBlank) },
        )
    }

    /**
     * Web probe: the same builder, client and headers as [sendRelayCapabilityTest], but it **keeps** this turn's
     * web fragment (the caller puts it into [ChatRequestOptions.relayWebFragments], merged the same way as in chat); sent once and read in full,
     * and for a 2xx the reply is handed to the same citation-parsing context as chat (strategy + shape) to extract evidence.
     */
    internal suspend fun sendRelayWebProbe(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
        extras: RelayChatBuildExtras,
        progress: RelayWebProbe.Progress? = null,
    ): RelayWebProbeReply {
        validateChatRequest(apiKey, modelID, requestOptions)
        val routed = routed(requestOptions, baseUrl)
        val wire = buildRelayChatStreamRequest(apiKey, modelID, messages, baseUrl, ReasoningMode.Automatic, routed, extras)
        return client.preparePost(wire.url) {
            applyRelayHeaders(apiKey, routed, wire.transport)
            contentType(ContentType.Application.Json)
            setBody(wire.body)
        }.execute { response ->
            val status = response.status.value
            val contentType = response.contentType()?.toString()
            if (status !in 200..299) {
                return@execute RelayWebProbeReply(
                    RelayCapabilityTestResponse.Http(status, contentType, response.bodyAsText()),
                    RelayWebProbeEvidence.None,
                )
            }
            val context = resolveCitationContext(routed, wire.transport)
            if (!RelayWebProbe.isEventStream(contentType)) {
                val body = response.bodyAsText()
                return@execute RelayWebProbeReply(
                    RelayCapabilityTestResponse.Http(status, contentType, body),
                    RelayWebProbe.evidence(body, contentType, context.strategy, context.shape),
                )
            }
            // Judge while receiving: feed lines to this protocol's production parser and stop reading at a citation URL (or an error frame before evidence); leaving execute cancels the request.
            progress?.status = status
            val scan = RelayWebProbe.EvidenceScan(context.strategy, context.shape, progress)
            val channel = response.bodyAsChannel()
            val body = StringBuilder()
            while (true) {
                val line = channel.readUTF8Line() ?: break
                body.append(line).append('\n')
                if (scan.feedLine(line)) break
            }
            RelayWebProbeReply(RelayCapabilityTestResponse.Http(status, contentType, body.toString()), scan.evidence)
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
        if (RelayProtocolFallback.isHtmlSuccessPage(response.status.value, body, response.contentType()?.toString())) {
            throw relayHtmlPageError(response.status.value)
        }
    }

    /** A 2xx that is a web page (the gateway's SPA fallback page): this path is not an API route, and both the probe and protocol fallback treat it as a route-level rejection. */
    private fun relayHtmlPageError(statusCode: Int): ProviderServiceError =
        ProviderServiceError.RelayUpstream(
            statusCode = statusCode,
            guidance = WEB_PAGE_RETURNED_GUIDANCE,
            detail = "The relay returned an HTML page instead of a generation response.",
            guidanceCode = RelayGuidanceCode.WebPageReturned,
        ).also { it.relayHtmlSuccessPage = true }

    /** A streaming send rejects a web-page 200 before output starts: the body is not read yet, so only the Content-Type is checked. */
    private fun throwIfRelayHtmlPage(response: HttpResponse) {
        if (RelayProtocolFallback.isHtmlSuccessPage(response.status.value, "", response.contentType()?.toString())) {
            throw relayHtmlPageError(response.status.value)
        }
    }

    /**
     * A streaming 2xx whose Content-Type claims SSE but whose first non-blank body line is a web page: report the web-page sentence before output starts,
     * and enter protocol fallback as a route-level rejection. It only peeks and consumes nothing, so a normal stream goes to each protocol's parser as before; blank lines do not count as the first line.
     */
    @OptIn(io.ktor.utils.io.InternalAPI::class)
    private suspend fun throwIfRelayHtmlStream(response: HttpResponse) {
        if (!response.status.isSuccess()) return
        val channel = response.rawContent
        var wanted = 1
        while (wanted <= STREAM_PAGE_SNIFF_MAX_BYTES) {
            val more = channel.awaitContent(wanted)
            val available = channel.availableForRead
            if (available == 0) return
            val head = channel.peek(available)?.toByteArray()?.toString(Charsets.UTF_8) ?: return
            when (RelayProtocolFallback.streamHeadIsWebPage(head)) {
                true -> throw relayHtmlPageError(response.status.value)
                false -> return
                null -> if (!more) return
            }
            wanted = available + 1
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
        return run {
            val transport = RelayTransport.OpenAIChatCompletions
            val upstreamUrl = buildUrl(baseUrl, "/chat/completions", requestOptions, apiKey, transport)
            val requestBody = buildOpenAIChatBody(
                modelID = modelID,
                messages = messages,
                stream = false,
                reasoningMode = reasoningMode,
                requestOptions = requestOptions,
                capabilityProjection = requestCapabilityProjection(
                    requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages,
                ),
            )

            var result: StreamEvent.Done? = null
            // One HTTP attempt per body. The landing-and-resend after a rejected thinking tier lives in the dispatch layer; the inner layer never reissues a body of its own.
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
                    val rawText = choice.message.content
                    val text = rawText.trim()
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
                            rawText = rawText,
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
            run {
                flow {
                    val transport = RelayTransport.OpenAIChatCompletions
                    val upstreamUrl = buildUrl(baseUrl, "/chat/completions", requestOptions, apiKey, transport)
                    val requestBody = buildOpenAIChatBody(
                        modelID = modelID,
                        messages = messages,
                        stream = true,
                        reasoningMode = reasoningMode,
                        requestOptions = requestOptions,
                        capabilityProjection = requestCapabilityProjection(
                            requestOptions, modelID, transport, upstreamUrl, reasoningMode, messages,
                        ),
                    )

                    // Parse citations with the chat-completions strategy plus the streamShape of the profile
                    // inferred from the web fragment merged into this turn.
                    val citationCtx = resolveCitationContext(
                        requestOptions = requestOptions,
                        fallbackTransport = transport,
                    )
                    val toolCallParser = NativeToolCallParser(NativeToolProtocol.OpenAIChat)

                    // The status decision completes before anything is emitted, so the outer
                    // layer's retry can never emit the same tokens twice.
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
                            throwIfRelayHtmlPage(response)
                            if (!response.status.isSuccess()) {
                                throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                            }
                            throwIfRelayHtmlStream(response)

                            var accumulatedText = ""
                            var lastUsage: Usage? = null

                            SseParser.parseOpenAICompatibleMulti(
                                response = response,
                                json = json,
                                stopFamily = StopFamily.OPENAI_CHAT,
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
     * llama.cpp native `/completion` goes through the same send-once path: `n_predict` and
     * `temperature` in the body, along with the generation parameters injected by
     * `GenerationParameterResolver`, are all optional, and one version bump of the local engine can
     * be enough for it to reject them with a 400 - which is reported rather than worked around.
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
            result = StreamEvent.Done(ProviderChatResult(text = content.trim(), estimatedCost = 0.0, rawText = content))
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
                // Only a final chunk with stop:true counts as clean; disconnecting without it = eof_without_marker
                val finishTracker = StreamFinishTracker(StopFamily.LLAMA_CPP)
                response.bodyAsChannel().toInputStream().sseLineReader().use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        val payload = line.removePrefix("data: ").trim()
                        if (payload.isEmpty() || payload == "[DONE]") continue
                        val delta = llamaCppContent(payload, relayCredentialMaterial(response), finishTracker)
                        if (delta.isNotEmpty()) {
                            accumulated += delta
                            emit(StreamEvent.Delta(delta))
                        }
                    }
                }
                emit(
                    StreamEvent.Done(
                        ProviderChatResult(text = accumulated.trim(), estimatedCost = 0.0),
                        finish = finishTracker.finish(),
                    ),
                )
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

    private fun llamaCppContent(payload: String, credentials: Collection<String>, finishTracker: StreamFinishTracker? = null): String {
        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
            ?: throw ProviderServiceError.Network("Invalid llama.cpp response.")
        finishTracker?.observe(root)
        root["content"]?.jsonPrimitive?.content?.let { return it }
        root["error"]?.jsonObject?.get("message")?.jsonPrimitive?.content?.let {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = SseParser.withUpstreamRaw("The custom LLM returned an error.", payload, credentials),
                streamErrorFrame = true,
            )
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
            // The older tool classification expresses a structured rejection through an internal signal only; the outer layer surfaces it
            // and does not send a second request. A rejected thinking tier lands on another tier in the dispatch layer.
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
                        // No access: never resend with changed settings.
                        if (statusCode in 400..499 && !RelayKeyAccess.isModelAccessDenied(statusCode, rawBody)) {
                            val payload = RelayErrorMapper.parseUpstreamErrorPayload(rawBody)
                            if (!hints.removeTools
                                && RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, statusCode)
                            ) {
                                throw RelayResponsesRejectedSettingSignal(RelayRetryHints(removeTools = true))
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
                    val rawText = parsed.resolvedText
                    val text = rawText.trim()
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
                            rawText = rawText,
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

    /**
     * Converts a rejected-setting signal into a plain upstream error.
     *
     * Exactly one unchanged upstream attempt is made; an optional setting the endpoint refuses is
     * surfaced to the user rather than silently stripped and retried. The request context is taken
     * so the call sites read the same as the other Relay send wrappers.
     */
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
                            throwIfRelayHtmlPage(response)
                            if (!response.status.isSuccess()) {
                                val statusCode = response.status.value
                                val rawBody = response.bodyAsText()
                                // On an HTTP 4xx the rejected setting is recorded structurally, and
                                // the outer layer surfaces exactly one failure.
                                // No access: never resend with changed settings.
                                if (statusCode in 400..499 && !RelayKeyAccess.isModelAccessDenied(statusCode, rawBody)) {
                                    val payload = RelayErrorMapper.parseUpstreamErrorPayload(rawBody)
                                    if (!hints.removeTools
                                        && RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, statusCode)
                                    ) {
                                        throw RelayResponsesRejectedSettingSignal(RelayRetryHints(removeTools = true))
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

                            throwIfRelayHtmlStream(response)

                            // Parse citations with the Responses strategy plus the streamShape of the profile
                            // inferred from the web fragment merged into this turn.
                            val citationCtx = resolveCitationContext(
                                requestOptions = requestOptions,
                                fallbackTransport = transport,
                            )

                            var accumulatedText = ""
                            var lastUsage: ResponsesUsage? = null
                            var firstContentEmitted = false
                            val emittedImageIds = mutableSetOf<String>()
                            var currentEvent = ""
                            // Only the **last** data line matters: a malformed chunk mid-stream is
                            // reset by the next good one, while a dropped final line is exactly the
                            // "incomplete trailing line" the SSE spec describes — the upstream was
                            // cut while writing it.
                            var lastChunkDropped = false
                            val finishTracker = StreamFinishTracker(StopFamily.OPENAI_RESPONSES)
                            val toolCallParser = NativeToolCallParser(NativeToolProtocol.OpenAIResponses)

                            response.bodyAsChannel()
                                .toInputStream()
                                .sseLineReader()
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
                                                finishTracker.observePayload(payload, json, currentEvent)

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

                                                // When the upstream goes away mid-line, BufferedReader.readLine() still returns the
                                                // trailing partial line at EOF, so half a JSON object reaches decodeFromString and the
                                                // resulting JsonDecodingException tears down the whole stream.
                                                // Every other parse path already tolerates a malformed chunk here; this hand-rolled
                                                // loop did not, because it bypasses the shared parser.
                                                // Only SerializationException is swallowed: ProviderServiceError and
                                                // RelayResponsesRejectedSettingSignal raised by the `response.failed` / `error`
                                                // branches are not subclasses of it and still propagate unchanged.
                                                val parsedChunk = SseParser.tolerantParseChunk {
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
                                                        // response.incomplete (e.g. max_output_tokens) also carries the final usage
                                                        "response.completed", "response.incomplete" -> {
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
                                                                detail = SseParser.withUpstreamRaw(
                                                                    "The custom LLM Responses stream reported a failure.",
                                                                    payload,
                                                                    relayCredentialMaterial(response),
                                                                ),
                                                                streamErrorFrame = true,
                                                                streamFinish = if (currentEvent == "response.failed") {
                                                                    StreamFinishTracker.responsesFailedFinish(
                                                                        runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull(),
                                                                        currentEvent,
                                                                    )
                                                                } else {
                                                                    null
                                                                },
                                                            ).also { it.telemetryUpstreamErrorType = SseParser.upstreamErrorTypeOf(payload) }
                                                        }
                                                    }
                                                }
                                                lastChunkDropped = parsedChunk == null

                                                currentEvent = ""
                                            }
                                        }
                                    }
                                }

                            // The tolerance should absorb a half-written line, not the fact that the
                            // stream was cut. Without this, the text accumulated so far is delivered as
                            // Done and stored as a finished reply — no truncation hint, no retry — and if
                            // `response.completed` was the line that got cut, usage stays null and the
                            // turn is recorded as 0 tokens at 0 cost. Network matches what the llama.cpp
                            // loop already raises when its payload fails to parse.
                            if (lastChunkDropped) {
                                throw ProviderServiceError.Network(
                                    "The custom LLM Responses stream ended mid-event.",
                                )
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
                                    finish = finishTracker.finish(),
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
        val transport = resolveTransport(requestOptions)
        return RelayErrorMapper.mapOrDefault(
            status = statusCode,
            body = body,
            upstreamUrl = upstreamUrl,
            context = RelayErrorContext(
                relayKind = relayKind,
                transport = transport,
                authMode = resolveAuthMode(requestOptions, transport),
                modelID = modelID,
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

                val parsed = decodeRelaySuccessResponse<AnthropicResponse>(response)
                val rawText = parsed.resolvedText
                val text = rawText.trim()
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
                        rawText = rawText,
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

        // Parse citations with the Anthropic strategy plus the streamShape of the profile
        // inferred from the web fragment merged into this turn.
        val citationCtx = resolveCitationContext(
            requestOptions = requestOptions,
            fallbackTransport = transport,
        )

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
                throwIfRelayHtmlPage(response)
                if (!response.status.isSuccess()) {
                    throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                }
                throwIfRelayHtmlStream(response)

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
                    stopFamily = StopFamily.ANTHROPIC,
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
        // promptFeedback.blockReason only appears when the prompt was blocked: any non-empty value blocks (including future new values)
        val blockReason = parsed.promptFeedback?.blockReason
        if (!blockReason.isNullOrBlank()) {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini blocked the prompt: $blockReason",
                streamFinish = StreamFinishTracker.geminiPromptBlockedFinish(blockReason),
                inBandFailure = ai.oriveo.community.core.model.UpstreamInBandFailure.ContentFiltered,
            )
        }
        val finishReason = parsed.candidates?.firstOrNull()?.finishReason
        if (finishReason != null && finishReason in GEMINI_BLOCKED_REASONS) {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini stopped generation: $finishReason",
                streamFinish = StreamFinishTracker.geminiBlockedFinish(finishReason),
                inBandFailure = ai.oriveo.community.core.model.UpstreamInBandFailure.ContentFiltered,
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

                val parsed = decodeRelaySuccessResponse<GenerateResponse>(response)
                throwIfGeminiBlocked(parsed)
                val parts = parsed.candidates?.firstOrNull()?.content?.parts.orEmpty()
                val rawText = parts.mapNotNull { it.text }.joinToString("")
                val text = rawText.trim()
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
                        rawText = rawText,
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

        // Parse citations with the Gemini strategy plus the streamShape of the profile
        // inferred from the web fragment merged into this turn.
        val citationCtx = resolveCitationContext(
            requestOptions = requestOptions,
            fallbackTransport = transport,
        )

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
                throwIfRelayHtmlPage(response)
                if (!response.status.isSuccess()) {
                    throw mapRelayHttpError(response, upstreamUrl, requestOptions, modelID)
                }
                throwIfRelayHtmlStream(response)

                var accumulatedText = ""
                var lastUsage: UsageMeta? = null
                val attachments = mutableListOf<Attachment>()
                val toolCallParser = NativeToolCallParser(NativeToolProtocol.GeminiGenerate)

                SseParser.parseGeminiStreamMulti(
                    response = response,
                    json = json,
                    stopFamily = StopFamily.GEMINI,
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
        val path = endpointPath
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
            path = "/messages",
            requestOptions = requestOptions,
            apiKey = apiKey,
            transport = transport,
        )
    }

    private fun buildUrl(
        baseUrl: String?,
        path: String,
        requestOptions: ChatRequestOptions? = null,
        apiKey: String? = null,
        transport: RelayTransport? = null,
        extraQuery: List<Pair<String, String>> = emptyList(),
    ): String {
        // The API root is resolved per model and injected by the entry point ([routed]); calls without request options (catalog sync and the like) use the address the caller gave.
        val base = resolveUrl(requestOptions?.relayRouteAPIRoot?.takeIf { it.isNotBlank() } ?: baseUrl)
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
        /** false = this request belongs to no chat protocol (catalog sync /models, standalone image generation), so the error context treats the protocol as unknown. */
        transportKnown: Boolean = true,
    ): ProviderServiceError {
        val transport = resolveTransport(requestOptions)
        val body = response.bodyAsText()
        return RelayErrorMapper.mapOrDefault(
            status = response.status.value,
            body = body,
            upstreamUrl = upstreamUrl,
            context = RelayErrorContext(
                relayKind = relayKind,
                transport = transport.takeIf { transportKnown },
                authMode = resolveAuthMode(requestOptions, transport),
                modelID = modelID,
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

    /**
     * Response body of a catalog refresh -> model ids in upstream order (before sorting and chat-model filtering). It uses the same decoder and Json configuration as [syncProvider],
     * and all three shells (OpenAI list / new-api success / Anthropic page) take only `data[].id` (key-binding shellCases).
     */
    internal fun decodeRelayCatalogIDs(body: String): List<String> =
        json.decodeFromString<ModelsResponse>(body).data.map { it.id }

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
            // It cannot be decoded because the reply is a web page: a non-streaming send treats this as a route-level rejection and switches protocol, and reports the web-page sentence.
            val htmlPage =
                RelayProtocolFallback.isHtmlSuccessPage(response.status.value, body, response.contentType()?.toString())
            throw ProviderServiceError.RelayUpstream(
                statusCode = response.status.value,
                guidance = if (htmlPage) WEB_PAGE_RETURNED_GUIDANCE else MALFORMED_SUCCESS_RESPONSE_GUIDANCE,
                // SerializationException.message embeds the raw response body, and the failure card
                // shows technicalDetail, so only a stable classification is kept here. HTML, the
                // prompt, or a credential echoed back by the upstream must not end up in the error.
                detail = "The custom LLM returned malformed JSON.",
                guidanceCode = if (htmlPage) RelayGuidanceCode.WebPageReturned else null,
            ).also { it.relayHtmlSuccessPage = htmlPage }
        }
    }

    private fun resolveTransport(requestOptions: ChatRequestOptions): RelayTransport =
        requestOptions.relayRouteTransport
            ?: RelayEndpointResolver.effectiveTransport(requestOptions.relayRequested, requestOptions.activeModel)

    /**
     * The outbound entry fixes this request's protocol and API root: what the caller (ChatRepository via RelayService) injected per
     * (connection, model) is used as is; if nothing was injected, it is computed from the connection copy in the request options and activeModel, through the same resolver.
     */
    private fun routed(requestOptions: ChatRequestOptions, baseUrl: String?): ChatRequestOptions {
        if (requestOptions.relayRouteTransport != null && !requestOptions.relayRouteAPIRoot.isNullOrBlank()) {
            return requestOptions
        }
        return requestOptions.copy(
            relayRouteTransport = resolveTransport(requestOptions),
            relayRouteAPIRoot = requestOptions.relayRouteAPIRoot?.takeIf { it.isNotBlank() }
                ?: RelayEndpointResolver.effectiveAPIRoot(requestOptions.relayRequested, baseUrl, requestOptions.activeModel),
        )
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
        val effectiveReasoning = reasoningMode
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
        val projection = CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = requestOptions.relayRequested,
            identity = identity,
            keys = keys,
            explicitKeys = explicitKeys,
        )
        return withRelayUnknownVision(projection, requestOptions, model, modelId, effectiveTransport)
    }

    /**
     * When relay image input is unknown, the image is sent anyway; if the upstream really rejects it, an image negative cache entry is recorded and a hint card is shown, the same rule as the album entry.
     * It is let through only when there is no negative evidence (declared unsupported, or the protocol envelope does not accept images), there is a connection identity, and the image negative cache for the key is not hit
     * (an override of true outranks the negative cache); otherwise the projection's original decision stands.
     */
    private fun withRelayUnknownVision(
        projection: CapabilityEvidenceProductionAdapter.Projection,
        requestOptions: ChatRequestOptions,
        model: AIModel,
        modelId: String,
        effectiveTransport: RelayTransport,
    ): CapabilityEvidenceProductionAdapter.Projection {
        val decision = projection.decision("vision_input") ?: return projection
        if (decision.permitsOutbound || decision.resolution.support == "unsupported") return projection
        val connectionId = requestOptions.capabilityEvidenceIdentity?.connectionInstanceId ?: return projection
        if (MetadataClient.relayRuntimeConfig().transportEnvelopes[effectiveTransport.value]?.image != true) return projection
        val key = RelayNegativeCache.Key(connectionId, modelId, effectiveTransport.value)
        if (model.relayCapabilityOverrides?.image != true && negativeCache.isRejected(key, RelayNegativeCache.Kind.Image)) {
            return projection
        }
        return projection.copy(decisions = projection.decisions + ("vision_input" to decision.copy(permitsOutbound = true)))
    }

    /**
     * Resolves the citation-parsing context for a relay stream:
     * - the strategy is chosen from `relayRequested.transportKind` first, which is the wire kind
     *   string the user typed in custom mode (`openai_responses`, `anthropic_messages` and so on).
     *   When that override is absent or does not parse, fall back to the transport this request is
     *   actually using.
     * - the shape is the profile inferred from the web fragment merged into this turn (fixture `citationCases`), looked up in the catalog's profile
     *   table. No fragment, or a profile that cannot be inferred, yields null
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
    ): RelayCitationContext {
        val overrideStrategy = requestOptions.relayRequested?.transportKind
            ?.let { runCatching { transportRegistry.strategyForWireValue(it) }.getOrNull() }
        val strategy = overrideStrategy
            ?: transportRegistry.strategy(transportKindFor(fallbackTransport))
        val profile = RelayWebFragments.citationProfile(
            fallbackTransport,
            requestOptions.relayWebFragments[fallbackTransport.value],
        )
        val shape = profile?.let { StreamShape.fromMetadata(MetadataClient.webSearchStreamShape(it)) }
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
                    val (groupKey, groupName) = RelayFamilyHeuristics.groupMetadata(family)
                    baseModel.copy(groupKey = groupKey, groupName = groupName)
                } else {
                    baseModel
                }
                if (normalizedPreferred == remote.id) grouped.copy(isDefault = true) else grouped
            }
            .sortedWith(CATALOG_ORDER)

        if (normalizedPreferred != null && models.any { it.isDefault }) {
            return models
        }
        if (models.isEmpty()) return emptyList()
        val default = models.firstOrNull { it.isDefault } ?: models.first()
        return models.map { if (it.id == default.id) it.copy(isDefault = true) else it.copy(isDefault = false) }
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
    private data class RemoteModel(
        val id: String,
        val created: Double? = null,
        // Kept as raw JSON: gateways occasionally put non-string items here, and this one column must not make the whole catalog fail to decode.
        @SerialName("supported_endpoint_types") val supportedEndpointTypes: JsonElement? = null,
    )

    /** Same rule as the add-time discovery: ids are trimmed, a duplicate id keeps its first occurrence, and only string items are taken. */
    private fun endpointTypes(remoteModels: List<RemoteModel>): Map<String, List<String>> {
        val result = linkedMapOf<String, List<String>>()
        val seen = hashSetOf<String>()
        remoteModels.forEach { remote ->
            val id = remote.id.trim()
            if (id.isEmpty() || !seen.add(id)) return@forEach
            (remote.supportedEndpointTypes as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content }
                ?.let { result[id] = it }
        }
        return result
    }

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
        /** A Gemini thinking-summary part is marked true (includeThoughts). */
        val thought: Boolean? = null,
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
