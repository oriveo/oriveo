package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionOutbound
import ai.oriveo.community.core.provider.openai.codexReasoningEffort
import ai.oriveo.community.core.provider.grok.GrokSubscriptionOutbound
import ai.oriveo.community.core.provider.relay.relayChatCompletionsReasoningJson
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.provider.transport.ProviderTransportDefinition
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.TransportEndpoints
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.applyProfileMergeParams
import ai.oriveo.community.core.provider.transport.deepMergeJsonObject
import ai.oriveo.community.core.provider.transport.parseJsonObjectOrNull
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Base class for OpenAI-compatible providers.
 *
 * Groq, Together, Fireworks and Relay share this implementation; only the baseUrl and the model
 * filtering logic differ.
 *
 * It covers vision and reasoning capability detection, the `reasoning_effort` parameter (same
 * shape as OpenAI's), and attachment formats (image_url and inline text).
 *
 * Capability wiring:
 *   - [transportRegistry] supplies the openai_chat strategy, which parses annotations into
 *     Citations while streaming.
 *   - The webSearch profile's mergeParams are injected into the body by
 *     [applyProfileMergeParams].
 */
open class OpenAICompatibleService(
    protected val client: HttpClient,
    protected val json: Json,
    private val defaultBaseUrl: String,
    private val providerName: String,
    private val providerKind: ProviderKind = ProviderKind.Relay,
    /**
     * The strategy registry, injected so the streaming path can parse citations. Every subclass
     * (DeepSeek / Groq / Together / Fireworks / SiliconFlow / MiniMax / Moonshot / Zhipu / Qwen /
     * Relay) inherits transportRegistry from here.
     */
    protected val transportRegistry: TransportRegistry? = null,
) : ProviderService {

    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult {
        val url = resolveBaseUrl(baseUrl)
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        if (providerKind != ProviderKind.Relay) {
            MetadataClient.ensureInitialized()
            return ProviderSyncResult(models = emptyList())
        }

        val response = client.get("$url/models") {
            applyHeaders(apiKey)
        }

        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

        val body = response.bodyAsText()
        val models = parseModels(body, preferredModelID)

        if (models.isEmpty()) throw ProviderServiceError.EmptyModelCatalog
        return ProviderSyncResult(models = models)
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
        if (providerKind != ProviderKind.Relay) {
            MetadataClient.ensureInitialized()
        }

        val resolved = if (providerKind != ProviderKind.Relay) {
            MetadataClient.resolveCatalogModel(modelID, providerKind)
        } else null
        val subscription = requestOptions.grokSubscription
        // The Codex subscription is pinned to `/responses`: that is the only endpoint on this
        // path, and its models are likewise absent from the catalog (`resolved` is always null).
        // Without an explicit check the request would fall through to the chat/completions
        // fallback below and come back as a 404. The test is whether a subscription context is
        // present, not the model id.
        val codexSubscription = requestOptions.openAISubscription
        val transportKind = when {
            codexSubscription != null -> TransportKind.OpenAIResponses
            subscription?.usesResponses == true -> TransportKind.OpenAIResponses
            subscription != null -> TransportKind.OpenAIChat
            else -> TransportKind.fromWireValue(resolved?.transport) ?: TransportKind.OpenAIChat
        }

        if (transportKind == TransportKind.OpenAIResponses) {
            emitAll(
                sendOpenAIResponsesStream(
                    apiKey = apiKey,
                    modelID = modelID,
                    messages = messages,
                    baseUrl = baseUrl,
                    reasoningMode = reasoningMode,
                    webSearchEnabled = webSearchEnabled,
                    requestOptions = requestOptions,
                    resolved = resolved,
                )
            )
            return@flow
        }

        val endpoint = when {
            // Subscription mode takes the entire URL straight from the parsed configuration
            // rather than splicing it onto a catalog transport path. The two sides have opposite
            // conventions about who owns `/v1` (here the base already carries it, there the path
            // does), so splicing yields `.../v1/v1/chat/completions` and upstream answers nothing
            // but a 404.
            subscription != null -> subscription.chatUrl
            providerKind == ProviderKind.Grok && baseUrl.isNullOrBlank() -> resolveEndpoint(
                customBaseUrl = null,
                kind = EndpointResolver.EndpointKind.CHAT,
            )
            else -> "${resolveBaseUrl(baseUrl)}/chat/completions"
        }
        val requestBody = forceMiniMaxReasoningSplit(applyCapabilityRuntimeCustomFragment(buildChatRequest(
            modelID, messages, stream = true,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            supportsImageGen = supportsImageGen,
            requestOptions = requestOptions,
            resolved = resolved,
        ), providerKind, modelID, TransportKind.OpenAIChat.wireValue, requestOptions)).let { body ->
            // Thinking levels on the subscription path: the machinery above spins uselessly here
            // because a capability recipe requires a catalog entry, and not one subscription
            // model has one. The result was a panel that let the user pick a level while the
            // request carried no such field at all.
            // The level value can only ever come from the set upstream declares in `/models`
            // (`codexReasoningEffort` is the same function the UI's `subscriptionVerdict` uses),
            // and if nothing maps we send nothing. What this guards against is sending a level
            // value upstream does not recognize, which is the exact shape of the Grok
            // reasoning_effort incident.
            val effort = if (subscription == null) null else codexReasoningEffort(
                reasoningMode.rawValue,
                requestOptions.activeModel?.let {
                    CapabilityControlResolution.subscriptionDeclaredReasoningLevels(providerKind, it)
                }.orEmpty(),
            )
            if (effort == null) body else mergeParamsIntoBody(
                body,
                JsonObject(mapOf("reasoning_effort" to JsonPrimitive(effort))),
            )
        }
        val continuationRecipe = if (providerKind != ProviderKind.Relay) {
            capabilityRuntimeContinuationSelection(
                providerKind, modelID, TransportKind.OpenAIChat.wireValue, webSearchEnabled, reasoningMode,
            )?.takeIf { it.continuationKind == "replay_reasoning" }
        } else null

        // openai_chat strategy plus the matching streamShape (Zhipu's field path for
        // web_search.search_result and its link field name).
        val strategy = transportRegistry?.strategy(TransportKind.OpenAIChat)
        val webProfileName = resolved?.profiles?.webSearch
        val shape = if (webSearchEnabled) {
            ai.oriveo.community.core.provider.transport.StreamShape.fromMetadata(
                MetadataClient.webSearchStreamShape(webProfileName)
            )
        } else null

        // Sent exactly once. A deterministic upstream 400 that names an unsupported parameter is
        // surfaced with that name; nothing is dropped and resent behind the user's back.
        UnsupportedParamRetry.run(
            providerKind,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = officialSelfHealIdentity(
                providerKind = providerKind,
                modelID = modelID,
                options = requestOptions,
                finalTransport = TransportKind.OpenAIChat.wireValue,
                finalUrl = endpoint,
            ),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(endpoint) {
                applyHeaders(apiKey, subscription)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    throw SseParser.mapHttpError(response, subscription = subscription != null)
                }

                var accumulatedText = ""
                var accumulatedReasoning = ""
                var lastUsageJson: JsonObject? = null
                val replayAccumulator = continuationRecipe?.responseParserKind?.let {
                    ProviderRecipeExecution.ReasoningAssistantAccumulator(it)
                }
                val nativeToolParser = NativeToolCallParser(NativeToolProtocol.OpenAIChat)
                val thinkingTagParser = if (providerKind == ProviderKind.MiniMax) {
                    ThinkingTagParser()
                } else {
                    null
                }

                SseParser.parseOpenAICompatibleMulti(
                    response = response,
                    json = json,
                    onChunk = { payload ->
                        val events = mutableListOf<StreamEvent>()
                        // Parsed as a JSON tree so a subclass parseUsage can reach the raw fields,
                        // including cached_tokens and reasoning_tokens.
                        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
                        if (root != null) {
                            // OpenAI-compatible: usage sits at the top level.
                            // Note that with stream_options.include_usage=true, mid-stream chunks
                            // carry "usage":null (a JsonNull). It has to be filtered with
                            // `as? JsonObject`, never falling back to `.jsonObject`, which throws
                            // on JsonNull. That throw would swallow the entire chunk inside
                            // SseParser's try/catch and lose the delta with it - the root cause of
                            // DeepSeek returning completely empty responses.
                            (root["usage"] as? JsonObject)?.let { lastUsageJson = it }
                            // Groq is a special case: usage may hide in x_groq.usage.
                            ((root["x_groq"] as? JsonObject)?.get("usage") as? JsonObject)
                                ?.let { lastUsageJson = it }
                            ((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)?.let { choice ->
                                val delta = choice["delta"] as? JsonObject
                                val message = choice["message"] as? JsonObject
                                (delta ?: message)?.let {
                                    replayAccumulator?.ingest(it, completeMessage = delta == null && message != null)
                                }
                            }
                            nativeToolParser.parse(null, root).takeIf { it.isNotEmpty() }?.let {
                                events += StreamEvent.ToolCallDeltas(it)
                            }
                        }

                        // Citation parsing; the strategy already wraps this in runCatching.
                        if (strategy != null) {
                            val cits = runCatching { strategy.parseCitations(payload, shape) }
                                .getOrNull()
                                .orEmpty()
                            if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)
                        }

                        // Thinking models such as Mistral Magistral send delta.content as an array
                        // of blocks (type=thinking / type=text). The typed StreamChunk only
                        // accepts a String content, so without splitting these off first the whole
                        // decode fails and the deltas are silently lost. Done provider-agnostically
                        // (a Relay endpoint pointing at the same shape benefits too) rather than as
                        // a per-kind special case.
                        val deltaContentElement = ((root?.get("choices") as? JsonArray)
                            ?.firstOrNull() as? JsonObject)
                            ?.let { it["delta"] as? JsonObject }
                            ?.get("content")
                        if (deltaContentElement is JsonArray) {
                            for (segment in parseContentBlockSegments(deltaContentElement)) {
                                when (segment) {
                                    is ContentBlockSegment.Text -> {
                                        accumulatedText += segment.value
                                        events += StreamEvent.Delta(segment.value)
                                    }
                                    is ContentBlockSegment.Reasoning -> {
                                        accumulatedReasoning += segment.value
                                        events += StreamEvent.Reasoning(segment.value)
                                    }
                                }
                            }
                        } else {
                            // Deltas still go through the typed StreamChunk decode (usage was
                            // already pulled out above as a JsonObject); the fast paths for
                            // providers whose content is a String are unchanged.
                            val chunk = runCatching { json.decodeFromString<StreamChunk>(payload) }.getOrNull()
                            val deltaObject = chunk?.choices?.firstOrNull()?.delta
                            // Groq, Together (gpt-oss), OpenRouter and some other OpenAI-compatible
                            // services put reasoning deltas in delta.reasoning, without the
                            // _content suffix, so both names are checked.
                            val reasoningDelta = deltaObject?.reasoning_content
                                ?: deltaObject?.reasoning
                            // An empty string is deliberately not discarded: while thinking,
                            // upstreams such as DeepSeek send only reasoning_content:"" heartbeats
                            // and do not emit the real thinking content until the whole segment is
                            // finished. When measured, the first non-empty reasoning chunk arrived
                            // after 279 seconds. Dropping the heartbeats leaves the UI with
                            // minutes of zero output, where the user cannot tell "thinking" apart
                            // from "hung". A missing field (null) still produces no event.
                            // These are also two independent branches rather than one if/else, so
                            // that reasoning and content arriving in the same frame do not
                            // suppress each other.
                            if (reasoningDelta != null) {
                                accumulatedReasoning += reasoningDelta
                                events += StreamEvent.Reasoning(reasoningDelta)
                            }
                            val delta = deltaObject?.content
                            if (!delta.isNullOrEmpty()) {
                                if (thinkingTagParser != null) {
                                    for (segment in thinkingTagParser.parse(delta)) {
                                        when (segment) {
                                            is ThinkingTagParser.Segment.Text -> {
                                                accumulatedText += segment.value
                                                events += StreamEvent.Delta(segment.value)
                                            }
                                            is ThinkingTagParser.Segment.Reasoning -> {
                                                accumulatedReasoning += segment.value
                                                events += StreamEvent.Reasoning(segment.value)
                                            }
                                        }
                                    }
                                } else {
                                    accumulatedText += delta
                                    events += StreamEvent.Delta(delta)
                                }
                            }
                        }
                        events
                    },
                    onDone = {
                        if (thinkingTagParser != null) {
                            for (segment in thinkingTagParser.parse("", final = true)) {
                                when (segment) {
                                    is ThinkingTagParser.Segment.Text -> accumulatedText += segment.value
                                    is ThinkingTagParser.Segment.Reasoning -> accumulatedReasoning += segment.value
                                }
                            }
                        }
                        val breakdown = parseUsage(lastUsageJson)
                        val resolved = if (providerKind != ProviderKind.Relay) {
                            MetadataClient.resolveCatalogModel(modelID, providerKind)
                        } else null
                        val (cost, source) = CostCalculator.calcCost(
                            breakdown, resolved, isSubscription = subscription != null,
                        )
                        StreamEvent.Done(
                            ProviderChatResult(
                                text = accumulatedText.trim(),
                                promptTokens = breakdown.promptTokens + breakdown.cachedInputTokens,
                                completionTokens = breakdown.completionTokens,
                                estimatedCost = cost,
                                reasoningText = accumulatedReasoning.trim().takeIf { it.isNotEmpty() },
                                cachedInputTokens = breakdown.reportedCachedInputTokens,
                                cacheCreation5mTokens = breakdown.reportedCacheCreation5mTokens,
                                cacheCreation1hTokens = breakdown.reportedCacheCreation1hTokens,
                                costSource = source.name,
                            )
                        )
                    },
                ).collect { event ->
                    if (event is StreamEvent.Done && continuationRecipe != null) {
                        replayAccumulator?.stateOrNull()?.let { state ->
                            emit(StreamEvent.RecipeContinuation("replay_reasoning", continuationRecipe.continuationVariant, state))
                        }
                    }
                    emit(event)
                }
            }
        }
    }

    /**
     * Non-streaming send, with image generation dispatched purely by route (the imageGen
     * profile's route is the sole authority).
     *
     * The images_api route (the OpenAI shape `/images/generations` returning
     * data[].b64_json|url) is handled once here in the base class, so every first-party provider
     * sharing that wire (Grok / Zhipu / SiliconFlow) works with zero provider-specific code, and
     * the body's default fields all come from the catalog's requestDefaults - things like size can
     * be corrected there rather than being hardcoded in the client.
     *
     * Other routes are not intercepted here. MiniMax uses /image_generation and overrides this
     * first. Qwen's route=dashscope_multimodal (not images_api) falls through to the default
     * branch that collects the stream, and its own stream image branch handles it. chat_api
     * (inline generation) lands on the chat stream. When supportsImageGen is set but the route is
     * missing or unknown, this throws InvalidConfiguration and fails loudly; it must never
     * silently fall back to chat, which was the root cause of a three-layer bug.
     */
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
        // Make sure catalog metadata is ready before a first-party provider's first request
        // (matching sendMessageStream and OpenAIService), otherwise route and requestDefaults read
        // as empty and image generation dispatch degrades.
        if (providerKind != ProviderKind.Relay) {
            MetadataClient.ensureInitialized()
        }
        if (supportsImageGen && providerKind != ProviderKind.Relay) {
            val resolved = MetadataClient.resolveCatalogModel(modelID, providerKind)
            // The route is the only authoritative signal for image generation dispatch. Missing
            // or unknown fails loudly; silently falling back to chat is what caused the old bug.
            when (MetadataClient.imageGenRoute(resolved?.profiles?.imageGen)) {
                "images_api" ->
                    return generateImageViaImagesApi(apiKey, modelID, messages, baseUrl, resolved)
                // dashscope_multimodal and minimax_image_generation are intercepted earlier by
                // their subclass overrides and never reach this base-class branch. chat_api
                // (inline generation) falls through to the chat stream below, where the image
                // comes back as a stream event.
                "dashscope_multimodal", "minimax_image_generation", "chat_api" -> Unit
                else -> throw ProviderServiceError.InvalidConfiguration(
                    "Image generation route is missing or unknown for this model.",
                )
            }
        }
        if (apiKey.isBlank() || modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing provider credentials.")
        val resolved = MetadataClient.resolveCatalogModel(modelID, providerKind)
        val subscription = requestOptions.grokSubscription
        val responses = subscription?.usesResponses == true ||
            (subscription == null && TransportKind.fromWireValue(resolved?.transport) == TransportKind.OpenAIResponses)
        val endpoint = when {
            subscription?.usesResponses == true -> subscription.responsesUrl
                ?: throw ProviderServiceError.InvalidConfiguration("Missing Grok subscription responses endpoint.")
            subscription != null -> subscription.chatUrl
            else -> resolveEndpoint(baseUrl, if (responses) EndpointResolver.EndpointKind.RESPONSES else EndpointResolver.EndpointKind.CHAT)
        }
        val body = if (subscription?.usesResponses == true) {
            buildGrokSubscriptionResponsesBody(modelID, messages, reasoningMode, requestOptions, stream = false)
        } else if (responses) buildResponsesRequest(
            modelID, messages, false, reasoningMode, webSearchEnabled, requestOptions, resolved,
        ) else forceMiniMaxReasoningSplit(applyCapabilityRuntimeCustomFragment(
            buildChatRequest(modelID, messages, false, reasoningMode, webSearchEnabled, supportsImageGen, requestOptions, resolved),
            providerKind, modelID, TransportKind.OpenAIChat.wireValue, requestOptions,
        ))
        val response = client.post(endpoint) {
            applyHeaders(apiKey, subscription); contentType(ContentType.Application.Json); setBody(body)
        }
        if (!response.status.isSuccess()) {
            throw SseParser.mapHttpError(response, subscription = subscription != null)
        }
        val root = json.parseToJsonElement(response.bodyAsText()).jsonObject
        val text = if (responses) {
            (root["output_text"] as? JsonPrimitive)?.contentOrNull ?: (root["output"] as? JsonArray).orEmpty()
                .flatMap { ((it as? JsonObject)?.get("content") as? JsonArray).orEmpty() }
                .mapNotNull { ((it as? JsonObject)?.get("text") as? JsonPrimitive)?.contentOrNull }
                .joinToString("")
        } else {
            val content = ((((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)?.get("message") as? JsonObject)?.get("content"))
            when (content) {
                is JsonPrimitive -> content.contentOrNull.orEmpty()
                is JsonArray -> parseContentBlockSegments(content).filterIsInstance<ContentBlockSegment.Text>().joinToString("") { it.value }
                else -> ""
            }
        }
        if (text.isBlank()) throw ProviderServiceError.EmptyResponse
        val usage = root["usage"] as? JsonObject
        val breakdown = if (responses) parseResponsesUsage(usage) else parseUsage(usage)
        val (cost, source) = CostCalculator.calcCost(breakdown, resolved, isSubscription = subscription != null)
        return StreamEvent.Done(ProviderChatResult(
            text.trim(), breakdown.promptTokens + breakdown.cachedInputTokens, breakdown.completionTokens,
            cost, reasoningText = null, cachedInputTokens = breakdown.reportedCachedInputTokens, costSource = source.name,
        ))
    }

    /**
     * The shared images_api implementation: POST {base}/images/generations with
     * body={model,prompt} plus requestDefaults, parsing data[].b64_json|url.
     */
    private suspend fun generateImageViaImagesApi(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): StreamEvent.Done {
        val prompt = messages.lastOrNull { it.role.name == "User" }?.text?.trim()
        if (prompt.isNullOrBlank()) {
            throw ProviderServiceError.InvalidConfiguration("Image generation requires a text prompt.")
        }
        val requestDefaults = MetadataClient.imageGenRequestDefaults(resolved?.profiles?.imageGen)
        val body = buildJsonObject {
            put("model", modelID)
            put("prompt", prompt)
            requestDefaults?.forEach { (key, value) -> put(key, value) }
        }.toString()

        val response = client.post("${resolveBaseUrl(baseUrl)}/images/generations") {
            applyHeaders(apiKey)
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

        val data = json.parseToJsonElement(response.bodyAsText()).jsonObject["data"]?.jsonArray
            ?: throw ProviderServiceError.EmptyResponse
        val attachments = data.mapNotNull { element ->
            val obj = element.jsonObject
            val b64 = obj["b64_json"]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
            val url = obj["url"]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
            val mime = obj["mime_type"]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() } ?: "image/png"
            when {
                b64 != null -> imageAttachment(base64OrUrl = b64, mime = mime)
                url != null -> imageAttachment(base64OrUrl = url, mime = mime) // the URL is downloaded later by ChatRepository
                else -> null
            }
        }
        if (attachments.isEmpty()) throw ProviderServiceError.EmptyResponse
        return StreamEvent.Done(ProviderChatResult(text = "", attachments = attachments))
    }

    private fun imageAttachment(base64OrUrl: String, mime: String): Attachment {
        val ext = when {
            mime.contains("jpeg") || mime.contains("jpg") -> "jpg"
            mime.contains("webp") -> "webp"
            else -> "png"
        }
        return Attachment(
            id = java.util.UUID.randomUUID().toString(),
            kind = AttachmentKind.Image,
            fileName = "generated_image.$ext",
            mimeType = mime,
            base64Data = base64OrUrl,
        )
    }

    private fun sendOpenAIResponsesStream(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): Flow<StreamEvent> = flow {
        // The Codex subscription builds its entire request on its own. The first-party path is
        // keyed by models in the metadata catalog (capability recipe, previous_response_id, the
        // 400 self-heal, generation parameter templates), and subscription models are not in the
        // catalog, so `resolved` is always null there and going through it would silently drop
        // the six hard constraints this path actually needs.
        val codex = requestOptions.openAISubscription
        val grok = requestOptions.grokSubscription
        val requestBody = if (grok?.usesResponses == true) {
            buildGrokSubscriptionResponsesBody(modelID, messages, reasoningMode, requestOptions)
        } else if (codex != null) {
            OpenAISubscriptionOutbound.buildResponsesBody(
                modelID = modelID,
                inputElementsJson = MessageBuilder.buildOpenAIResponsesInput(
                    messages,
                    requestOptions.activeModel,
                ),
                // Android's ChatRole only has user and assistant, and the system prompt has always
                // travelled in options, so there is nothing to strip out of messages here.
                systemPrompt = MessageBuilder.normalizeRequestOptions(requestOptions).systemPrompt,
                webSearchRequested = webSearchEnabled,
                // What upstream declares about web search for *this* model, copied verbatim from
                // `/models` when the catalog entry was built. It is an independent condition from
                // the user's intent (see the parameter docs on `buildResponsesBody`).
                webSearchDeclared = requestOptions.activeModel
                    ?.capabilities?.contains(ModelCapability.Web) == true,
                reasoningMode = reasoningMode.rawValue,
                declaredReasoningLevels = requestOptions.activeModel?.let {
                    CapabilityControlResolution.subscriptionDeclaredReasoningLevels(providerKind, it)
                }.orEmpty(),
            )
        } else {
            buildResponsesRequest(
                modelID = modelID,
                messages = messages,
                stream = true,
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                requestOptions = requestOptions,
                resolved = resolved,
            )
        }
        // The subscription path has no recipe, so there is no continuation strategy to speak of,
        // and `previous_response_id` is mutually exclusive with `store:false` anyway.
        val continuationRecipe = if (codex != null || grok != null) null else capabilityRuntimeContinuationSelection(
            providerKind, modelID, TransportKind.OpenAIResponses.wireValue, webSearchEnabled, reasoningMode,
        )?.takeIf { it.continuationKind == "previous_id" }
        // The subscription endpoint takes its entire URL from the parsed configuration and never
        // splices it onto a catalog baseUrl: taking a subscription token to api.openai.com only
        // earns an error message with no relation to the real cause.
        val endpoint = grok?.responsesUrl
            ?: codex?.responsesUrl
            ?: resolveEndpoint(customBaseUrl = baseUrl, kind = EndpointResolver.EndpointKind.RESPONSES)
        val strategy = transportRegistry?.strategy(TransportKind.OpenAIResponses)
        val webProfileName = resolved?.profiles?.webSearch
        val shape = if (webSearchEnabled) {
            ai.oriveo.community.core.provider.transport.StreamShape.fromMetadata(
                MetadataClient.webSearchStreamShape(webProfileName)
            )
        } else null

        UnsupportedParamRetry.run(
            providerKind,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = officialSelfHealIdentity(
                providerKind = providerKind,
                modelID = modelID,
                options = requestOptions,
                finalTransport = TransportKind.OpenAIResponses.wireValue,
                finalUrl = endpoint,
            ),
        ) { requestBodyAttempt ->
            val statement = client.preparePost(endpoint) {
                applyHeaders(apiKey, grok)
                codex?.let { context ->
                    // Required for SSE. The account identity is the copy resolved during
                    // authorization and is deliberately not re-decoded from the access token here:
                    // the claim actually lives in the id_token, and the access token is not
                    // guaranteed to carry it.
                    header("Accept", "text/event-stream")
                    header("chatgpt-account-id", context.accountId)
                    // originator / version / OpenAI-Beta are the published required headers; miss
                    // any one of them and /responses rejects the request.
                    context.requiredHeaders.forEach { (name, value) -> header(name, value) }
                }
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) {
                    // A 401, 403, 426 or 429 on the subscription path each mean something
                    // different, and filing them under the key-mode classification turns them all
                    // into "try a different key" - which a subscription user has no way to act on.
                    throw SseParser.mapHttpError(response, when {
                        codex != null -> ProviderSubscriptionLane.OpenAI
                        grok != null -> ProviderSubscriptionLane.Grok
                        else -> ProviderSubscriptionLane.None
                    })
                }

                var accumulatedText = ""
                var accumulatedReasoning = ""
                var lastUsageJson: JsonObject? = null
                var completedResponseId: String? = null
                val nativeToolParser = NativeToolCallParser(NativeToolProtocol.OpenAIResponses)

                SseParser.parseOpenAICompatibleMulti(
                    response = response,
                    json = json,
                    onChunk = { payload ->
                        val events = mutableListOf<StreamEvent>()
                        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
                        if (root != null) {
                            nativeToolParser.parse(root["type"]?.jsonPrimitive?.contentOrNull, root)
                                .takeIf { it.isNotEmpty() }
                                ?.let { events += StreamEvent.ToolCallDeltas(it) }
                        }

                        if (root != null && strategy != null) {
                            val cits = runCatching { strategy.parseCitations(payload, shape) }
                                .getOrNull()
                                .orEmpty()
                            if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)
                        }

                        val type = root?.get("type")?.jsonPrimitive?.contentOrNull
                        when (type) {
                            "response.output_text.delta" -> {
                                val delta = root["delta"]?.jsonPrimitive?.contentOrNull.orEmpty()
                                if (delta.isNotEmpty()) {
                                    accumulatedText += delta
                                    events += StreamEvent.Delta(delta)
                                }
                            }
                            "response.reasoning.delta",
                            "response.reasoning_summary_text.delta",
                            "response.reasoning_summary.delta",
                            -> {
                                val delta = root["delta"]?.jsonPrimitive?.contentOrNull.orEmpty()
                                if (delta.isNotEmpty()) {
                                    accumulatedReasoning += delta
                                    events += StreamEvent.Reasoning(delta)
                                }
                            }
                            "response.completed" -> {
                                lastUsageJson = (root["usage"] as? JsonObject)
                                    ?: ((root["response"] as? JsonObject)?.get("usage") as? JsonObject)
                                completedResponseId = ((root["response"] as? JsonObject)?.get("id") as? JsonPrimitive)?.contentOrNull
                                    ?: (root["id"] as? JsonPrimitive)?.contentOrNull
                            }
                            "response.failed",
                            "error",
                            -> {
                                val detail = ((root["error"] as? JsonObject)?.get("message")
                                    ?: ((root["response"] as? JsonObject)
                                        ?.get("error") as? JsonObject)
                                        ?.get("message"))
                                    ?.jsonPrimitive
                                    ?.contentOrNull
                                    ?: "Responses stream failed."
                                throw ProviderServiceError.Upstream(statusCode = 200, detail = detail)
                            }
                        }

                        events
                    },
                    onDone = {
                        val breakdown = parseResponsesUsage(lastUsageJson)
                        val (cost, source) = CostCalculator.calcCost(
                            breakdown,
                            resolved,
                            isSubscription = codex != null || grok != null,
                        )
                        StreamEvent.Done(
                            ProviderChatResult(
                                text = accumulatedText.trim(),
                                promptTokens = breakdown.promptTokens + breakdown.cachedInputTokens,
                                completionTokens = breakdown.completionTokens,
                                estimatedCost = cost,
                                reasoningText = accumulatedReasoning.trim().takeIf { it.isNotEmpty() },
                                cachedInputTokens = breakdown.reportedCachedInputTokens,
                                cacheCreation5mTokens = breakdown.reportedCacheCreation5mTokens,
                                cacheCreation1hTokens = breakdown.reportedCacheCreation1hTokens,
                                costSource = source.name,
                            )
                        )
                    },
                ).collect { event ->
                    if (event is StreamEvent.Done && continuationRecipe != null) {
                        completedResponseId?.takeIf { it.isNotBlank() }?.let { id ->
                            emit(StreamEvent.RecipeContinuation("previous_id", state = JsonObject(mapOf("previousResponseId" to JsonPrimitive(id)))))
                        }
                    }
                    emit(event)
                }
            }
        }
    }

    private fun buildGrokSubscriptionResponsesBody(
        modelID: String,
        messages: List<ChatMessage>,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        stream: Boolean = true,
    ): String {
        val model = requestOptions.activeModel
        return GrokSubscriptionOutbound.buildResponsesBody(
            modelID = modelID,
            inputElementsJson = MessageBuilder.buildOpenAIResponsesInput(messages, model),
            systemPrompt = MessageBuilder.normalizeRequestOptions(requestOptions).systemPrompt,
            supportsWebSearch = model?.capabilities?.contains(ModelCapability.Web) == true,
            reasoningMode = reasoningMode.rawValue,
            declaredReasoningLevels = model?.let {
                CapabilityControlResolution.subscriptionDeclaredReasoningLevels(providerKind, it)
            }.orEmpty(),
            defaultReasoningLevel = CapabilityControlResolution.subscriptionDefaultReasoningLevel(
                providerKind,
                model,
            ),
            stream = stream,
        )
    }

    /**
     * Parses an upstream `usage` JSON object into the unified [UsageBreakdown]. This is the
     * default OpenAI-compatible template; subclasses override it where their response fields
     * differ (Moonshot's top-level cached_tokens, Qwen's native DashScope shape, Grok's
     * cost_in_usd_ticks and so on).
     *
     * The default follows the OpenAI template:
     *   - promptTokens = prompt_tokens - cached_tokens
     *   - cachedInputTokens = prompt_tokens_details.cached_tokens
     *   - completionTokens = completion_tokens (already includes reasoning)
     *   - reasoningTokens = completion_tokens_details.reasoning_tokens (informational)
     */
    protected open fun parseUsage(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val prompt = usage["prompt_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val completion = usage["completion_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val cached = (usage["prompt_tokens_details"] as? JsonObject)
            ?.get("cached_tokens")?.jsonPrimitive?.intOrNull ?: 0
        val cacheReadObserved = (usage["prompt_tokens_details"] as? JsonObject)
            ?.get("cached_tokens")?.jsonPrimitive?.intOrNull != null
        val reasoning = (usage["completion_tokens_details"] as? JsonObject)
            ?.get("reasoning_tokens")?.jsonPrimitive?.intOrNull ?: 0
        return UsageBreakdown(
            promptTokens = (prompt - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            cacheCreation5mTokens = 0,
            cacheCreation1hTokens = 0,
            completionTokens = completion,
            reasoningTokens = reasoning,
            upstreamCost = null,
            cacheReadObserved = cacheReadObserved,
        )
    }

    // ── Overridable by subclasses ──

    /** Filters models by id. */
    protected open fun filterModel(id: String): Boolean = true

    /** Filters by the type field the API returns (Together uses "chat"). */
    protected open fun filterByType(type: String?): Boolean = true

    // ── Protected ──

    protected fun resolveBaseUrl(custom: String?): String {
        val url = (custom?.takeIf { it.isNotBlank() } ?: defaultBaseUrl).trimEnd('/')
        return if (url.startsWith("http")) url else "https://$url"
    }

    private fun resolveEndpoint(
        customBaseUrl: String?,
        kind: EndpointResolver.EndpointKind,
    ): String {
        if (!customBaseUrl.isNullOrBlank()) {
            val suffix = when (kind) {
                EndpointResolver.EndpointKind.CHAT -> "/chat/completions"
                EndpointResolver.EndpointKind.RESPONSES -> "/responses"
                EndpointResolver.EndpointKind.IMAGES -> "/images/generations"
                EndpointResolver.EndpointKind.EMBEDDINGS -> "/embeddings"
                EndpointResolver.EndpointKind.FILES -> "/files"
            }
            return "${resolveBaseUrl(customBaseUrl)}$suffix"
        }
        val provider = Provider(
            id = "runtime-${providerKind.name}",
            kind = providerKind,
            baseUrlText = null,
        )
        return EndpointResolver.resolveEndpoint(
            provider = provider,
            kind = kind,
            metadata = providerTransportDefinition(),
        )
    }

    private fun providerTransportDefinition(): ProviderTransportDefinition? {
        if (providerKind == ProviderKind.Relay) return null
        val transport = MetadataClient.providerTransport(providerKind) ?: return null
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

    /**
     * The standard bearer headers. When [subscription] is non-null, the required headers for the
     * subscription path are appended verbatim on top.
     *
     * Both the header names and their values come entirely from the published configuration. Once
     * `x-grok-client-version` falls below xAI's floor the result is a blanket 426, and changing a
     * constant in the client means a week of app review. This only passes them through as given
     * and never substitutes a local default. The parameter has a default value, so the request
     * shape of the other thirteen services is unchanged.
     */
    protected fun io.ktor.client.request.HttpRequestBuilder.applyHeaders(
        apiKey: String,
        subscription: ai.oriveo.community.core.provider.grok.GrokSubscriptionRequestContext? = null,
    ) {
        header("Accept", "application/json")
        header("Authorization", "Bearer $apiKey")
        subscription?.requiredHeaders?.forEach { (name, value) -> header(name, value) }
    }

    private fun parseModels(body: String, preferredModelID: String?): List<AIModel> {
        val parsed = json.decodeFromString<ModelsListResponse>(body)
        val normalized = preferredModelID?.trim()

        val models = parsed.data
            .filter { filterModel(it.id) && filterByType(it.type) }
            .map { rm ->
                CatalogModelBuilder.buildCatalogModel(
                    providerKind = providerKind,
                    runtimeModelId = rm.id,
                    fallbackName = rm.id.substringAfterLast("/"),
                    createdAt = rm.created,
                ).let { model ->
                    if (normalized == rm.id) model.copy(isDefault = true) else model
                }
            }
            .sortedBy { it.name }

        return if (models.any { it.isDefault }) {
            models
        } else if (models.isNotEmpty()) {
            val first = models.first()
            models.map { if (it.id == first.id) it.copy(isDefault = true) else it }
        } else {
            models
        }
    }

    /**
     * Injecting generation parameters has to be the last step: a value the user set explicitly in
     * the panel must override the default the builder wrote from catalog metadata (such as
     * anthropic's max_tokens or the maxOutputTokens fallback), and the wire name is always looked
     * up in profile.wire instead of passing the canonical id through. The base class handles this
     * in one place, so subclasses that override buildChatRequest, like Grok, are covered too as
     * long as they call super.
     */
    protected open fun buildChatRequest(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        supportsImageGen: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata? = if (providerKind != ProviderKind.Relay) {
            MetadataClient.resolveCatalogModel(modelID, providerKind)
        } else null,
    ): String {
        val projection = officialRequestCapabilityProjection(
            providerKind, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.OpenAIChat.wireValue,
        )
        return GenerationParameterResolver.apply(
        buildChatRequestBody(
            modelID = modelID,
            messages = messages,
            stream = stream,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            supportsImageGen = supportsImageGen,
            requestOptions = requestOptions,
            resolved = resolved,
            capabilityProjection = projection,
        ),
        requestOptions,
        resolved,
        projection,
        )
    }

    /** MiniMax OpenAI fallback requires a split opaque reasoning channel on every chat request. */
    private fun forceMiniMaxReasoningSplit(body: String): String {
        if (providerKind != ProviderKind.MiniMax) return body
        val parsed = parseJsonObjectOrNull(body) ?: return body
        return JsonObject(parsed + ("reasoning_split" to JsonPrimitive(true))).toString()
    }

    private fun buildChatRequestBody(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        supportsImageGen: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): String {
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        // Build the message array with MessageBuilder so attachments are included; subclasses can
        // override this for a provider-specific format.
        val msgs = buildMessagesJson(
            messages = messagesForCapabilityProjection(messages, capabilityProjection),
            systemPrompt = options.systemPrompt,
        )

        val extras = mutableListOf<String>()

        // In stream mode we ask the server to attach usage to the final chunk, otherwise tokens
        // come back as 0 and no cost can be shown. This follows the OpenAI-compatible protocol,
        // which MiniMax, DeepSeek and others adhere to strictly.
        if (stream) {
            extras.add(""""stream_options":{"include_usage":true}""")
        }

        // The webSearch and reasoning fragments are appended independently: webSearchJson carries
        // only tools, and the thinking level is always decided by buildReasoningJson. A mutually
        // exclusive structure here once forced thinking off whenever Kimi's web search was on.
        buildWebSearchJson(webSearchEnabled && capabilityProjection.permitsOutbound("web_search"))?.let {
            extras.add(it)
            // Web search injection for the path with no runtime envelope. Only relay reaches this
            // today: when there is an envelope the projection turns web_search off, and a
            // first-party provider with no envelope has it off as well. The fragment counts as
            // actually dispatched only once it is in extras; the recipe path tracks its own
            // confirmed facts.
            requestOptions.capabilityExecutionCollector?.noteLegacyWebSearchDispatched()
        }
        if (providerKind == ProviderKind.Relay) {
            buildReasoningJson(reasoningMode)?.let { extras.add(it) }
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { extras.add(it) }
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/max_tokens") ||
            capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens")) {
            MessageBuilder.maxTokensJson(options.maxTokens)?.let { extras.add(it) }
        }

        val extrasStr = if (extras.isNotEmpty()) "," + extras.joinToString(",") else ""
        var bodyJson =
            """{"model":"$modelID","stream":$stream,"messages":[${msgs}]$extrasStr}"""

        val runtime = if (providerKind != ProviderKind.Relay) {
            applyCapabilityRuntimeRecipes(
                bodyJson = bodyJson,
                providerKind = providerKind,
                modelID = modelID,
                finalTransport = TransportKind.OpenAIChat.wireValue,
                webRequested = webSearchEnabled,
                reasoningMode = reasoningMode,
                requestOptions = requestOptions,
            )
        } else {
            CapabilityRuntimeApplication(bodyJson, authoritativeRuntime = false)
        }
        bodyJson = runtime.body

        if (providerKind != ProviderKind.Relay && !runtime.authoritativeRuntime) {
            val reasoningParams = reasoningMergeParamsForRequest(
                modelID = modelID,
                reasoningMode = reasoningMode,
                resolved = resolved,
            )
            bodyJson = mergeParamsIntoBody(
                bodyJson,
                reasoningParams.takeIf { reasoningMode == ReasoningMode.Automatic ||
                    capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoningMode(resolved, reasoningMode).rawValue}") },
            )
        }

        // Inject profile.webSearch.mergeParams: for a non-Relay provider with web search enabled
        // and a model that carries a web profile, deep-merge mergeParams from the catalog.
        if (runtime.authoritativeRuntime || !webSearchEnabled || providerKind == ProviderKind.Relay ||
            !capabilityProjection.permitsOutbound("web_search")) return bodyJson
        val webProfileName = resolved?.profiles?.webSearch ?: return bodyJson
        val mergeParams = MetadataClient.webSearchMergeParams(webProfileName) ?: return bodyJson
        val baseObj = parseJsonObjectOrNull(bodyJson) ?: return bodyJson
        val merged = applyProfileMergeParams(
            baseBody = baseObj,
            profileName = webProfileName,
            mergeParams = mergeParams,
        )
        return merged.toString()
    }

    private fun buildResponsesRequest(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): String {
        val projection = officialRequestCapabilityProjection(
            providerKind, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.OpenAIResponses.wireValue,
        )
        val generated = GenerationParameterResolver.apply(
        buildResponsesRequestBody(
            modelID = modelID,
            messages = messages,
            stream = stream,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
            resolved = resolved,
            capabilityProjection = projection,
        ),
        requestOptions,
        resolved,
        projection,
        )
        return applyCapabilityRuntimeCustomFragment(
            generated, providerKind, modelID, TransportKind.OpenAIResponses.wireValue, requestOptions,
        )
    }

    private fun buildResponsesRequestBody(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): String {
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        val activeModel = MetadataClient.resolveAIModelForRouter(modelID, providerKind)
        val sections = mutableListOf<String>()
        sections += """"model":"$modelID""""
        sections += """"input":[${MessageBuilder.buildOpenAIResponsesInput(messagesForCapabilityProjection(messages, capabilityProjection), activeModel)}]"""
        sections += """"stream":$stream"""
        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { sections += it }
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens") ||
            capabilityProjection.permitsOutbound("generation_parameter/max_tokens")) {
            MessageBuilder.maxTokensJson(options.maxTokens, key = "max_output_tokens")?.let { sections += it }
        }
        if (options.systemPrompt.isNotBlank()) {
            sections += """"instructions":${escapeJsonString(options.systemPrompt)}"""
        }
        var bodyJson = "{${sections.joinToString(",")}}"

        val runtime = if (providerKind != ProviderKind.Relay) {
            applyCapabilityRuntimeRecipes(
                bodyJson = bodyJson,
                providerKind = providerKind,
                modelID = modelID,
                finalTransport = TransportKind.OpenAIResponses.wireValue,
                webRequested = webSearchEnabled,
                reasoningMode = reasoningMode,
                requestOptions = requestOptions,
            )
        } else {
            CapabilityRuntimeApplication(bodyJson, authoritativeRuntime = false)
        }
        bodyJson = runtime.body
        if (!runtime.authoritativeRuntime) {
            val reasoningParams = reasoningMergeParamsForRequest(
                modelID = modelID,
                reasoningMode = reasoningMode,
                resolved = resolved,
                // A runtime rejection is only applied by the Retry adapter at the request
                // boundary, where the full connection identity is available. Here there is no
                // partition, connection, generation, epoch or final endpoint, so a loosely
                // matched older cache entry must not be read.
                dropReasoning = false,
                dropReasoningEffort = false,
                dropEffort = false,
            )
            bodyJson = mergeParamsIntoBody(
                bodyJson,
                reasoningParams.takeIf { reasoningMode == ReasoningMode.Automatic ||
                    capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoningMode(resolved, reasoningMode).rawValue}") },
            )
        }

        if (runtime.authoritativeRuntime || !webSearchEnabled || providerKind == ProviderKind.Relay ||
            !capabilityProjection.permitsOutbound("web_search")) return bodyJson
        val webProfileName = resolved?.profiles?.webSearch ?: return bodyJson
        val mergeParams = MetadataClient.webSearchMergeParams(webProfileName) ?: return bodyJson
        val baseObj = parseJsonObjectOrNull(bodyJson) ?: return bodyJson
        val merged = applyProfileMergeParams(
            baseBody = baseObj,
            profileName = webProfileName,
            mergeParams = mergeParams,
        )
        return merged.toString()
    }

    private fun parseResponsesUsage(usage: JsonObject?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val input = usage["input_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val output = usage["output_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val cached = (usage["input_tokens_details"] as? JsonObject)
            ?.get("cached_tokens")?.jsonPrimitive?.intOrNull ?: 0
        val cacheReadObserved = (usage["input_tokens_details"] as? JsonObject)
            ?.get("cached_tokens")?.jsonPrimitive?.intOrNull != null
        val reasoning = (usage["output_tokens_details"] as? JsonObject)
            ?.get("reasoning_tokens")?.jsonPrimitive?.intOrNull ?: 0
        val ticks = usage["cost_in_usd_ticks"]?.jsonPrimitive?.longOrNull
        val upstreamCost = if (providerKind == ProviderKind.Grok) {
            ticks?.let { it / GrokService.GROK_TICKS_PER_USD }
        } else {
            null
        }
        return UsageBreakdown(
            promptTokens = (input - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            cacheCreation5mTokens = 0,
            cacheCreation1hTokens = 0,
            completionTokens = output,
            reasoningTokens = reasoning,
            upstreamCost = upstreamCost,
            cacheReadObserved = cacheReadObserved,
        )
    }

    private fun reasoningMergeParamsForRequest(
        modelID: String,
        reasoningMode: ReasoningMode,
        resolved: MetadataClient.ResolvedModelMetadata?,
        dropReasoning: Boolean = false,
        dropReasoningEffort: Boolean = false,
        dropEffort: Boolean = false,
    ): JsonObject? {
        if (dropReasoning) return null
        val profileName = resolved?.profiles?.reasoning ?: return null
        var params = MetadataClient.reasoningMergeParams(profileName, reasoningMode) ?: return null
        if (dropReasoningEffort) {
            params = stripUnsupportedParam(params, "reasoning_effort") ?: return null
        }
        if (dropEffort) {
            params = stripUnsupportedParam(params, "effort") ?: return null
        }
        return params.takeUnless { it.isEffectivelyEmpty() }
    }

    private fun stripUnsupportedParam(params: JsonObject, param: String): JsonObject? {
        val stripped = UnsupportedParamJson.stripParam(params.toString(), param) ?: return params
        return parseJsonObjectOrNull(stripped)?.takeUnless { it.isEffectivelyEmpty() }
    }

    private fun mergeParamsIntoBody(bodyJson: String, mergeParams: JsonObject?): String {
        if (mergeParams == null || mergeParams.isEffectivelyEmpty()) return bodyJson
        val base = parseJsonObjectOrNull(bodyJson) ?: return bodyJson
        return deepMergeJsonObject(base, mergeParams).toString()
    }

    private fun JsonElement.isEffectivelyEmpty(): Boolean = when (this) {
        is JsonObject -> values.all { it.isEffectivelyEmpty() }
        else -> false
    }

    // ── Hooks subclasses can override ──

    /** Builds the reasoning-related JSON fragment; subclasses override it for non-OpenAI shapes. */
    protected open fun buildReasoningJson(mode: ReasoningMode): String? {
        return relayChatCompletionsReasoningJson(mode)
    }

    /** Builds the web search JSON fragment; a non-null return replaces the reasoning fragment. */
    protected open fun buildWebSearchJson(enabled: Boolean): String? = null

    /**
     * Builds the messages array JSON. By default it dispatches per provider (DeepSeek collapses
     * content into a string, everything else uses OpenAI-compatible content parts). A subclass
     * should only override this when [MessageBuilder.buildChatCompletionsMessages] genuinely
     * cannot cover its shape - do not start a second construction path inside a subclass, or
     * other consumers such as the library retrieval leg will miss it.
     */
    protected open fun buildMessagesJson(messages: List<ChatMessage>, systemPrompt: String?): String {
        return MessageBuilder.buildChatCompletionsMessages(
            messages = messages,
            providerKind = providerKind,
            systemPrompt = systemPrompt,
        )
    }

    // ── Response Types ──

    @Serializable
    private data class ModelsListResponse(val data: List<RemoteModel> = emptyList())

    @Serializable
    private data class RemoteModel(
        val id: String,
        val created: Double? = null,
        val owned_by: String? = null,
        val type: String? = null, // Together uses this to filter chat models
        val display_name: String? = null,
    )

    @Serializable
    private data class StreamChunk(
        val choices: List<ChunkChoice>? = null,
    )

    @Serializable
    private data class ChunkChoice(val delta: ChunkDelta? = null)

    @Serializable
    private data class ChunkDelta(
        val content: String? = null,
        val reasoning_content: String? = null,
        // Groq, Together (gpt-oss) and OpenRouter use `reasoning`, without the _content suffix.
        val reasoning: String? = null,
    )
}

/**
 * The result of splitting an OpenAI-compatible content block array: thinking goes to reasoning,
 * prose goes to text, and the original order is preserved.
 */
internal sealed interface ContentBlockSegment {
    val value: String

    data class Text(override val value: String) : ContentBlockSegment
    data class Reasoning(override val value: String) : ContentBlockSegment
}

/**
 * Generic parser for a content block array. It is provider-agnostic, since a streaming
 * delta.content and a non-streaming message.content have the same shape.
 *
 * The measured shape from the Mistral Magistral family:
 * `[{"type":"thinking","thinking":[{"type":"text","text":"..."}],"closed":true},{"type":"text","text":"..."}]`
 * where thinking[].text becomes reasoning deltas and the text of a type=text block becomes prose.
 * The closing frame of a stream has an empty thinking array and naturally produces nothing, which
 * is harmless. Unknown block types are ignored for forward compatibility.
 */
internal fun parseContentBlockSegments(content: JsonArray): List<ContentBlockSegment> {
    val segments = mutableListOf<ContentBlockSegment>()
    for (element in content) {
        val block = element as? JsonObject ?: continue
        when ((block["type"] as? JsonPrimitive)?.contentOrNull) {
            "thinking" -> {
                val thinking = block["thinking"] as? JsonArray ?: continue
                for (piece in thinking) {
                    val pieceObject = piece as? JsonObject ?: continue
                    if ((pieceObject["type"] as? JsonPrimitive)?.contentOrNull != "text") continue
                    val text = (pieceObject["text"] as? JsonPrimitive)?.contentOrNull ?: continue
                    if (text.isNotEmpty()) segments += ContentBlockSegment.Reasoning(text)
                }
            }
            "text" -> {
                val text = (block["text"] as? JsonPrimitive)?.contentOrNull ?: continue
                if (text.isNotEmpty()) segments += ContentBlockSegment.Text(text)
            }
        }
    }
    return segments
}
