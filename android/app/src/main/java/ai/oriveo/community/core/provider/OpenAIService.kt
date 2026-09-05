package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
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
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.utils.io.jvm.javaio.toInputStream
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.nio.charset.StandardCharsets

/**
 * The OpenAI provider service.
 *
 * The first-party OpenAI path prefers the Responses API. Relay endpoints and custom
 * OpenAI-compatible endpoints stay on Chat Completions.
 *
 * Capability wiring:
 *   - [TransportRegistry] supplies the openai_responses and openai_chat strategies.
 *   - While streaming, `strategy.parseCitations` extracts `annotations[].url_citation`.
 *   - The webSearch profile's mergeParams are injected by [applyProfileMergeParams].
 */
class OpenAIService(
    private val client: HttpClient,
    private val json: Json,
    private val transportRegistry: TransportRegistry,
) : ProviderService {

    companion object {
        private const val BASE_URL = "https://api.openai.com/v1"
        // Relay and custom OpenAI-compatible endpoints still call `GET /v1/models` from the
        // client and filter locally. Relay is a legitimate exception to catalog-driven listing,
        // because its directory comes from the user's own machine.
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
    }

    /**
     * The only implementation of Codex (ChatGPT subscription) outbound requests lives in
     * [OpenAICompatibleService]'s subscription branch: the endpoint comes from the parsed
     * `responsesUrl`, `chatgpt-account-id` and the published required headers are mandatory,
     * the body is built by
     * [ai.oriveo.community.core.provider.openai.OpenAISubscriptionOutbound] (`store:false` plus
     * `include: reasoning.encrypted_content`), and failures are classified under
     * `ProviderSubscriptionLane.OpenAI`.
     *
     * This class does not extend OpenAICompatibleService, so without this delegate that branch
     * is unreachable dead code for an OpenAI provider: the subscription context is only set when
     * `kind == OpenAI`, and `kind == OpenAI` dispatches to exactly this class (see the service
     * dispatch table in `ProviderRepository`). The symptom is that authorization and the model
     * catalog both work fine - they run through the separate `OpenAISubscriptionOAuthClient`
     * path - and then sending a single message takes the subscription access token to the
     * first-party `api.openai.com/v1/responses`, where upstream answers "Missing scopes:
     * api.responses.write", which then gets filed as a key-mode 401 and shown to the user as
     * "Invalid API Key".
     *
     * Delegating rather than copying that logic over: a second copy would eventually be edited
     * on one side only, and this bug was caused by exactly that kind of gap between what a
     * comment claimed and what was actually wired up.
     */
    private val codexDelegate: OpenAICompatibleService by lazy {
        OpenAICompatibleService(
            client = client,
            json = json,
            // On the subscription branch the entire URL comes from the parsed configuration, so
            // these two values are unused there. They are set to this class's own constants so
            // they do not look like the endpoint source for that path.
            defaultBaseUrl = BASE_URL,
            providerName = "OpenAI",
            providerKind = ProviderKind.OpenAI,
            transportRegistry = transportRegistry,
        )
    }

    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")

        if (!usesOfficialOpenAIApi(baseUrl)) {
            // Relay or custom endpoint: keep the existing API-driven behaviour (the client
            // catalog exception).
            return syncProviderViaApi(apiKey, preferredModelID, baseUrl)
        }

        // First-party OpenAI is catalog-only: the key is merely checked to be non-empty, and the
        // model list is built by the resolver from catalog metadata.
        MetadataClient.ensureInitialized()

        return ProviderSyncResult(models = emptyList())
    }

    private suspend fun syncProviderViaApi(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult {
        val normalizedBase = resolveUrl(baseUrl)
        val response = client.get("$normalizedBase/models") {
            applyHeaders(apiKey)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

        val parsed = json.decodeFromString<ModelsResponse>(response.bodyAsText())
        val models = buildModels(
            remoteModels = parsed.data,
            preferredModelID = preferredModelID,
            useMetadata = false,
        )
        if (models.isEmpty()) throw ProviderServiceError.EmptyModelCatalog

        return ProviderSyncResult(models = models)
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
        validateChatRequest(apiKey, modelID)
        // Subscription outbound requests only have a streaming implementation (the codex branch
        // in `OpenAICompatibleService`). The Codex catalog currently declares no image
        // generation, so `supportsImageGen` is always false and the scheduler never routes a
        // subscription request here. If one ever does arrive, reject it explicitly rather than
        // letting it fall into the first-party branch below and take a subscription access token
        // to api.openai.com. That is precisely the shape of the "Missing scopes:
        // api.responses.write" incident, and silently hitting the wrong endpoint is far harder
        // to diagnose than an error.
        if (requestOptions.openAISubscription != null) {
            throw ProviderServiceError.InvalidConfiguration(
                "ChatGPT subscription chat requires the streaming path.",
            )
        }
        if (usesOfficialOpenAIApi(baseUrl)) {
            MetadataClient.ensureInitialized()
        }

        val isOfficial = usesOfficialOpenAIApi(baseUrl)
        if (!isOfficial) {
            return sendMessageViaChatCompletions(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                baseUrl = baseUrl,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = false,
                resolved = null,
                requestOptions = requestOptions,
            )
        }

        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.OpenAI)
        if (TransportKind.fromWireValue(resolved?.transport) == TransportKind.OpenAIChat) {
            return sendMessageViaChatCompletions(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                baseUrl = baseUrl,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                resolved = resolved,
                requestOptions = requestOptions,
            )
        }
        // The imageGen profile route is the sole authority on image generation dispatch: the
        // images_api route (the gpt-image family) goes to the first-party Images API. Everything
        // else (route=chat_api inline generation, or null) continues on Responses below.
        if (supportsImageGen && MetadataClient.imageGenRoute(resolved?.profiles?.imageGen) == "images_api") {
            return sendMessageViaImagesApi(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                resolved = resolved,
            )
        }

        val url = resolveUrl(baseUrl)
        val requestBody = buildResponsesBody(
            modelID = modelID,
            messages = messages,
            stream = false,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
            webSearchEnabled = webSearchEnabled,
            resolved = resolved,
        )
        var result: StreamEvent.Done? = null
        UnsupportedParamRetry.run(
            ProviderKind.OpenAI,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = responsesSelfHealIdentity(modelID, requestOptions, url),
        ) { requestBodyAttempt ->
            val statement = client.preparePost("$url/responses") {
                applyHeaders(apiKey)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                val statusCode = response.status.value
                val body = response.bodyAsText()

                if (isResponsesNotSupported(statusCode)) {
                    result = sendMessageViaChatCompletions(
                        apiKey = apiKey,
                        modelID = modelID,
                        messages = messages,
                        baseUrl = baseUrl,
                        supportsImageGen = supportsImageGen,
                        reasoningMode = reasoningMode,
                        webSearchEnabled = webSearchEnabled,
                        resolved = resolved,
                        requestOptions = requestOptions,
                    )
                    return@execute
                }

                if (!response.status.isSuccess()) {
                    throw mapHttpError(statusCode, body)
                }

                val parsed = json.decodeFromString<ResponsesResponse>(body)
                val text = parsed.resolvedText.trim()
                val attachments = parsed.resolvedAttachments
                if (text.isEmpty() && attachments.isEmpty()) {
                    throw ProviderServiceError.EmptyResponse
                }

                val breakdown = responsesUsageBreakdown(parsed.usage)
                result = StreamEvent.Done(
                    buildResult(
                        text = text,
                        attachments = attachments.ifEmpty { null },
                        breakdown = breakdown,
                        modelID = modelID,
                    ),
                )
            }
        }

        return result ?: throw ProviderServiceError.EmptyResponse
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
        validateChatRequest(apiKey, modelID)
        // The Codex subscription takes precedence over every first-party dispatch: this path
        // shares nothing with first-party Responses - not the endpoint, not the headers, not the
        // body, not the failure semantics. The test is whether a subscription context is present,
        // not the model id and not the baseUrl: a subscription instance has `baseUrlText` equal
        // to `kind.defaultBaseUrl`, so `usesOfficialOpenAIApi` is always true for it, and testing
        // any later would keep sending subscription requests to the platform API.
        requestOptions.openAISubscription?.let {
            codexDelegate.sendMessageStream(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                baseUrl = baseUrl,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                requestOptions = requestOptions,
            ).collect { event -> emit(event) }
            return@flow
        }
        if (usesOfficialOpenAIApi(baseUrl)) {
            MetadataClient.ensureInitialized()
        }

        if (!usesOfficialOpenAIApi(baseUrl)) {
            streamViaChatCompletions(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                baseUrl = baseUrl,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = false,
                resolved = null,
                requestOptions = requestOptions,
            ).collect { emit(it) }
            return@flow
        }

        val resolved = if (usesOfficialOpenAIApi(baseUrl)) {
            MetadataClient.resolveCatalogModel(modelID, ProviderKind.OpenAI)
        } else {
            null
        }
        if (TransportKind.fromWireValue(resolved?.transport) == TransportKind.OpenAIChat) {
            streamViaChatCompletions(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                baseUrl = baseUrl,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                resolved = resolved,
                requestOptions = requestOptions,
            ).collect { emit(it) }
            return@flow
        }

        val url = resolveUrl(baseUrl)
        val requestBody = buildResponsesBody(
            modelID = modelID,
            messages = messages,
            stream = true,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
            webSearchEnabled = webSearchEnabled,
            resolved = resolved,
        )
        val continuationRecipe = capabilityRuntimeContinuationSelection(
            ProviderKind.OpenAI, modelID, TransportKind.OpenAIResponses.wireValue, webSearchEnabled, reasoningMode,
        )?.takeIf { it.continuationKind == "previous_id" }

        // openai_responses strategy plus the matching streamShape, used to inject web_search for
        // the gpt-4o / 4.1 / 5 families.
        val strategy = transportRegistry.strategy(TransportKind.OpenAIResponses)
        val webProfileName = resolved?.profiles?.webSearch
        val shape = if (webSearchEnabled) {
            ai.oriveo.community.core.provider.transport.StreamShape.fromMetadata(
                MetadataClient.webSearchStreamShape(webProfileName)
            )
        } else null

        UnsupportedParamRetry.run(
            ProviderKind.OpenAI,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = responsesSelfHealIdentity(modelID, requestOptions, url),
        ) { requestBodyAttempt ->
            val statement = client.preparePost("$url/responses") {
                applyHeaders(apiKey)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (response.status.value == 404) {
                    val errorBody = response.bodyAsText()
                    if (isResponsesNotSupported(404)) {
                        streamViaChatCompletions(
                            apiKey = apiKey,
                            modelID = modelID,
                            messages = messages,
                            baseUrl = baseUrl,
                            supportsImageGen = supportsImageGen,
                            reasoningMode = reasoningMode,
                            webSearchEnabled = webSearchEnabled,
                            resolved = resolved,
                            requestOptions = requestOptions,
                        ).collect { emit(it) }
                        return@execute
                    }
                    throw mapHttpError(404, errorBody)
                }

                if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

                var accumulatedText = ""
                var lastUsage: ResponsesUsage? = null
                var completedResponseId: String? = null
                var currentEvent = ""
                val nativeToolParser = NativeToolCallParser(NativeToolProtocol.OpenAIResponses)
                response.bodyAsChannel()
                    .toInputStream()
                    .bufferedReader(StandardCharsets.UTF_8)
                    .use { reader ->
                        while (true) {
                            val line = reader.readLine() ?: break
                            when {
                                line.startsWith("event: ") -> {
                                    currentEvent = line.removePrefix("event: ").trim()
                                }

                                line.startsWith("data: ") -> {
                                    val payload = line.removePrefix("data: ").trim()
                                    if (payload.isEmpty() || payload == "[DONE]") {
                                        currentEvent = ""
                                        continue
                                    }

                                    // Citation parsing: annotations can hide inside several
                                    // different Responses events, so OpenAIResponsesStrategy
                                    // recursively scans for url_citation nodes.
                                    val cits = runCatching { strategy.parseCitations(payload, shape) }
                                        .getOrNull()
                                        .orEmpty()
                                    if (cits.isNotEmpty()) emit(StreamEvent.Citations(cits))
                                    runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()?.let { root ->
                                        nativeToolParser.parse(currentEvent, root).takeIf { it.isNotEmpty() }?.let {
                                            emit(StreamEvent.ToolCallDeltas(it))
                                        }
                                    }

                                    when (currentEvent) {
                                        "response.output_text.delta" -> {
                                            val delta = json.decodeFromString<ResponsesStreamDelta>(payload)
                                            val text = delta.delta.orEmpty()
                                            if (text.isNotEmpty()) {
                                                accumulatedText += text
                                                emit(StreamEvent.Delta(text))
                                            }
                                        }

                                        // Reasoning deltas on OpenAI Responses: for gpt-5 and the
                                        // o-series the actual event name is
                                        // `response.reasoning_summary_text.delta`. The sibling
                                        // names `response.reasoning.delta` and
                                        // `response.reasoning_summary.delta` are matched too, to
                                        // cover the variants across generations.
                                        "response.reasoning_summary_text.delta",
                                        "response.reasoning.delta",
                                        "response.reasoning_summary.delta" -> {
                                            val delta = json.decodeFromString<ResponsesStreamDelta>(payload)
                                            val chunk = delta.delta.orEmpty()
                                            if (chunk.isNotEmpty()) {
                                                emit(StreamEvent.Reasoning(chunk))
                                            }
                                        }

                                        "response.output_image.done",
                                        "response.image_generation_call.completed" -> {
                                            val imageDone = json.decodeFromString<ResponsesStreamImageDone>(payload)
                                            imageDone.result?.let { base64 ->
                                                emit(
                                                    StreamEvent.ImagePart(
                                                        Attachment(
                                                            id = java.util.UUID.randomUUID().toString(),
                                                            kind = AttachmentKind.Image,
                                                            fileName = "generated_image.png",
                                                            mimeType = "image/png",
                                                            base64Data = base64,
                                                        ),
                                                    ),
                                                )
                                            }
                                        }

                                        "response.completed" -> {
                                            val completed = json.decodeFromString<ResponsesStreamCompleted>(payload)
                                            lastUsage = completed.resolvedUsage
                                            completedResponseId = completed.response?.id
                                                ?: runCatching { json.parseToJsonElement(payload).jsonObject["id"]?.jsonPrimitive?.contentOrNull }.getOrNull()
                                        }

                                        // A fatal error inside a Responses stream arrives under
                                        // either of two event names, `response.failed` or
                                        // `error`. Missing `error` would deliver a truncated
                                        // reply as a Done, i.e. as a normal completion.
                                        "response.failed", "error" -> {
                                            throw ProviderServiceError.Upstream(
                                                statusCode = 200,
                                                detail = extractErrorMessage(payload) ?: "OpenAI Responses stream failed.",
                                            )
                                        }
                                    }

                                    currentEvent = ""
                                }
                            }
                        }
                    }

                val breakdown = responsesUsageBreakdown(lastUsage)
                if (continuationRecipe != null) {
                    completedResponseId?.takeIf { it.isNotBlank() }?.let { id ->
                        emit(StreamEvent.RecipeContinuation("previous_id", state = JsonObject(mapOf("previousResponseId" to JsonPrimitive(id)))))
                    }
                }
                emit(
                    StreamEvent.Done(
                        buildResult(
                            text = accumulatedText.trim(),
                            breakdown = breakdown,
                            modelID = modelID,
                        ),
                    ),
                )
            }
        }
    }

    private fun validateChatRequest(apiKey: String, modelID: String) {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing API key.")
        if (modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing model identifier.")
    }

    private fun buildModels(
        remoteModels: List<RemoteModel>,
        preferredModelID: String?,
        useMetadata: Boolean,
    ): List<AIModel> {
        val normalizedPreferred = preferredModelID?.trim()
        val providerKind = if (useMetadata) ProviderKind.OpenAI else ProviderKind.Relay

        val models = remoteModels
            .filter { isChatModel(it.id) }
            .map { remote ->
                CatalogModelBuilder.buildCatalogModel(
                    providerKind = providerKind,
                    runtimeModelId = remote.id,
                    fallbackName = remote.id,
                    createdAt = remote.created,
                ).let { model ->
                    if (normalizedPreferred == remote.id) model.copy(isDefault = true) else model
                }
            }
            .sortedWith(
                compareBy<AIModel> { it.groupName.orEmpty() }
                    .thenBy { it.name.lowercase() },
            )

        if (normalizedPreferred != null && models.any { it.isDefault }) {
            return models
        }

        return markDefaultModel(models)
    }

    private fun markDefaultModel(models: List<AIModel>): List<AIModel> {
        if (models.isEmpty()) return emptyList()
        // The default model is whichever the catalog marks isDefault, falling back to the first.
        val best = models.firstOrNull { it.isDefault } ?: models.first()
        return models.map { model ->
            if (model.id == best.id) model.copy(isDefault = true) else model.copy(isDefault = false)
        }
    }

    private fun isChatModel(id: String): Boolean {
        val lowered = id.lowercase()
        // heuristic-allow: Relay/custom OpenAI-compatible catalog filter only; official OpenAI catalog uses metadata.
        return EXCLUDED_PREFIXES.none { lowered.startsWith(it) }
    }

    private fun usesOfficialOpenAIApi(baseUrl: String?): Boolean {
        return resolveUrl(baseUrl) == BASE_URL
    }

    private fun resolveUrl(custom: String?): String {
        val url = (custom?.takeIf { it.isNotBlank() } ?: BASE_URL).trimEnd('/')
        return if (url.startsWith("http")) url else "https://$url"
    }

    private fun io.ktor.client.request.HttpRequestBuilder.applyHeaders(apiKey: String) {
        header("Accept", "application/json")
        header("Authorization", "Bearer $apiKey")
    }

    /**
     * The self-heal identity takes its transport and final URL from the branch that actually
     * dispatched; the two branches never share one value.
     */
    private fun responsesSelfHealIdentity(
        modelID: String,
        requestOptions: ChatRequestOptions,
        url: String,
    ) = officialSelfHealIdentity(
        providerKind = ProviderKind.OpenAI,
        modelID = modelID,
        options = requestOptions,
        finalTransport = TransportKind.OpenAIResponses.wireValue,
        finalUrl = "$url/responses",
    )

    private fun chatSelfHealIdentity(
        modelID: String,
        requestOptions: ChatRequestOptions,
        url: String,
    ) = officialSelfHealIdentity(
        providerKind = ProviderKind.OpenAI,
        modelID = modelID,
        options = requestOptions,
        finalTransport = TransportKind.OpenAIChat.wireValue,
        finalUrl = "$url/chat/completions",
    )

    /**
     * Generation parameters are injected at the outermost layer so that explicit values from the
     * panel override the catalog defaults the builder wrote.
     */
    private fun buildResponsesBody(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): String {
        val projection = officialRequestCapabilityProjection(
            ProviderKind.OpenAI, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.OpenAIResponses.wireValue,
        )
        val generated = GenerationParameterResolver.apply(buildResponsesBodyBase(
            modelID = modelID,
            messages = messages,
            stream = stream,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
            resolved = resolved,
            capabilityProjection = projection,
        ),
        requestOptions,
        resolved,
        projection)
        return applyCapabilityRuntimeCustomFragment(
            generated, ProviderKind.OpenAI, modelID, TransportKind.OpenAIResponses.wireValue, requestOptions,
        )
    }

    private fun buildResponsesBodyBase(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): String {
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        // Resolve the model for AttachmentRouter, which enables native Office handling and the
        // scanned-PDF fallback.
        val activeModel = MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.OpenAI)
        val input = MessageBuilder.buildOpenAIResponsesInput(messagesForCapabilityProjection(messages, capabilityProjection), activeModel)

        val sections = mutableListOf<String>()
        sections += """"model":"$modelID""""
        sections += """"input":[$input]"""
        sections += """"stream":$stream"""
        if (supportsImageGen) {
            sections += """"tools":[{"type":"image_generation"}]"""
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { sections += it }
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens") || capabilityProjection.permitsOutbound("generation_parameter/max_tokens")) MessageBuilder.maxTokensJson(options.maxTokens, key = "max_output_tokens")?.let { sections += it }
        if (options.systemPrompt.isNotBlank()) {
            sections += """"instructions":${escapeJsonString(options.systemPrompt)}"""
        }
        // The always-on reasoning.summary="auto" was dropped from the first-party OpenAI
        // Responses path.
        // Measured exchange (o4-mini with reasoning:{effort:"medium", summary:"auto"}):
        //   HTTP 400 "Your organization must be verified to generate reasoning summaries"
        // The same request without summary returns 200. The overwhelming majority of individual
        // users bringing their own key are on unverified organizations, so leaving summary on
        // makes OpenAI's thinking levels unusable 100% of the time.
        // The cost, stated plainly: summary is a precondition for
        // response.reasoning_summary_text.delta (parsed in this class's SSE branch and in
        // OpenAICompatibleService.kt), so with it gone the first-party Responses path emits no
        // reasoning events at all and the thinking summary stream disappears. That is a
        // deliberate trade: working beats having summaries but not working. While there is no
        // content the typing indicator still shows, so the bubble does not degrade to an empty
        // one - see showTypingIndicator in feature/chat/components/MessageBubble.kt.
        // Organization verification status is not detectable from the client, so an
        // "inject only when verified" rule is impossible. Restoring summaries would have to go
        // through a runtimeConfig.selfHealPatterns entry keyed on the fixed parameter name
        // (param="reasoning.summary").
        // Note this decision does not apply to Relay custom endpoints, which talk to the user's
        // own relay rather than an OpenAI organization; their summary handling stays in
        // relay/RelayBodyBuilders.kt.

        var baseJson = "{${sections.joinToString(",")}}"
        val runtime = applyCapabilityRuntimeRecipes(
            bodyJson = baseJson,
            providerKind = ProviderKind.OpenAI,
            modelID = modelID,
            finalTransport = TransportKind.OpenAIResponses.wireValue,
            webRequested = webSearchEnabled,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
        )
        baseJson = runtime.body
        if (!runtime.authoritativeRuntime) {
            baseJson = mergeParamsIntoBody(baseJson, reasoningMergeParams(resolved, reasoningMode).takeIf { reasoningMode == ReasoningMode.Automatic || capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoningMode(resolved, reasoningMode).rawValue}") })
        }
        if (runtime.authoritativeRuntime || !webSearchEnabled || !capabilityProjection.permitsOutbound("web_search")) return baseJson

        val profileName = resolved?.profiles?.webSearch
        val mergeParams = MetadataClient.webSearchMergeParams(profileName) ?: return baseJson
        if (profileName.isNullOrBlank()) return baseJson
        val baseObj = parseJsonObjectOrNull(baseJson) ?: return baseJson
        val merged = applyProfileMergeParams(
            baseBody = baseObj,
            profileName = profileName,
            mergeParams = mergeParams,
        )
        return merged.toString()
    }

    private fun buildImagesBody(
        modelID: String,
        messages: List<ChatMessage>,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): String {
        val prompt = latestUserPrompt(messages)
            ?: throw ProviderServiceError.InvalidConfiguration("Image generation requires a text prompt.")

        // requestDefaults is the only source of parameters here: the gpt-image family was
        // measured rejecting response_format (400 Unknown parameter), and size and n come from
        // the catalog too, so they can be corrected without an app release rather than being
        // hardcoded in the client.
        val requestDefaults = MetadataClient.imageGenRequestDefaults(resolved?.profiles?.imageGen)
        return buildJsonObject {
            put("model", modelID)
            put("prompt", prompt)
            requestDefaults?.forEach { (key, value) -> put(key, value) }
        }.toString()
    }

    private fun buildChatBody(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        supportsImageGen: Boolean,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): String {
        val projection = officialRequestCapabilityProjection(
            ProviderKind.OpenAI, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.OpenAIChat.wireValue,
        )
        val generated = GenerationParameterResolver.apply(buildChatBodyBase(
            modelID = modelID,
            messages = messages,
            stream = stream,
            reasoningMode = reasoningMode,
            supportsImageGen = supportsImageGen,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
            resolved = resolved,
            capabilityProjection = projection,
        ),
        requestOptions,
        resolved,
        projection)
        return applyCapabilityRuntimeCustomFragment(
            generated, ProviderKind.OpenAI, modelID, TransportKind.OpenAIChat.wireValue, requestOptions,
        )
    }

    private fun buildChatBodyBase(
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        reasoningMode: ReasoningMode,
        supportsImageGen: Boolean,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): String {
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        val messagesJson = MessageBuilder.buildOpenAIMessages(
            messages = messagesForCapabilityProjection(messages, capabilityProjection),
            providerKind = ProviderKind.OpenAI,
            systemPrompt = options.systemPrompt,
        )

        val extras = mutableListOf<String>()
        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { extras += it }
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/max_tokens") || capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens")) MessageBuilder.maxTokensJson(options.maxTokens)?.let { extras += it }
        if (stream) extras += """"stream_options":{"include_usage":true}"""

        val extrasJson = if (extras.isNotEmpty()) "," + extras.joinToString(",") else ""
        var bodyJson = """{"model":"$modelID","stream":$stream,"messages":[$messagesJson]$extrasJson}"""
        val runtime = applyCapabilityRuntimeRecipes(
            bodyJson = bodyJson,
            providerKind = ProviderKind.OpenAI,
            modelID = modelID,
            finalTransport = TransportKind.OpenAIChat.wireValue,
            webRequested = webSearchEnabled,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
        )
        bodyJson = runtime.body
        if (!runtime.authoritativeRuntime) {
            bodyJson = mergeParamsIntoBody(bodyJson, reasoningMergeParams(resolved, reasoningMode).takeIf { reasoningMode == ReasoningMode.Automatic || capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoningMode(resolved, reasoningMode).rawValue}") })
        }
        if (runtime.authoritativeRuntime || !webSearchEnabled || !capabilityProjection.permitsOutbound("web_search")) return bodyJson
        val profileName = resolved?.profiles?.webSearch ?: return bodyJson
        val mergeParams = MetadataClient.webSearchMergeParams(profileName) ?: return bodyJson
        val baseObj = parseJsonObjectOrNull(bodyJson) ?: return bodyJson
        return applyProfileMergeParams(
            baseBody = baseObj,
            profileName = profileName,
            mergeParams = mergeParams,
        ).toString()
    }

    private suspend fun sendMessageViaChatCompletions(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        resolved: MetadataClient.ResolvedModelMetadata?,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        val url = resolveUrl(baseUrl)
        val requestBody = buildChatBody(
            modelID = modelID,
            messages = messages,
            stream = false,
            reasoningMode = reasoningMode,
            supportsImageGen = supportsImageGen,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
            resolved = resolved,
        )

        var result: StreamEvent.Done? = null
        UnsupportedParamRetry.run(
            ProviderKind.OpenAI,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = chatSelfHealIdentity(modelID, requestOptions, url),
        ) { requestBodyAttempt ->
            val statement = client.preparePost("$url/chat/completions") {
                applyHeaders(apiKey)
                contentType(ContentType.Application.Json)
                setBody(requestBodyAttempt)
            }

            requestOptions.capabilityExecutionCollector?.confirmDispatched()
            statement.execute { response ->
                if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

                val body = response.bodyAsText()
                val parsed = json.decodeFromString<ChatCompletionResponse>(body)
                val choice = parsed.choices.firstOrNull() ?: throw ProviderServiceError.EmptyResponse
                val text = choice.message.content.trim()
                if (text.isEmpty()) throw ProviderServiceError.EmptyResponse

                val breakdown = usageBreakdown(parsed.usage)
                result = StreamEvent.Done(
                    buildResult(
                        text = text,
                        breakdown = breakdown,
                        modelID = modelID,
                    ),
                )
            }
        }

        return result ?: throw ProviderServiceError.EmptyResponse
    }

    private suspend fun sendMessageViaImagesApi(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): StreamEvent.Done {
        val requestBody = buildImagesBody(modelID, messages, resolved)
        val statement = client.preparePost("$BASE_URL/images/generations") {
            applyHeaders(apiKey)
            contentType(ContentType.Application.Json)
            setBody(requestBody)
        }

        var result: StreamEvent.Done? = null
        statement.execute { response ->
            if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

            val body = response.bodyAsText()
            val parsed = json.decodeFromString<ImagesGenerationResponse>(body)
            val attachments = parsed.resolvedAttachments
            if (attachments.isEmpty()) throw ProviderServiceError.EmptyResponse

            val breakdown = responsesUsageBreakdown(parsed.usage)
            result = StreamEvent.Done(
                buildResult(
                    text = "",
                    attachments = attachments,
                    breakdown = breakdown,
                    modelID = modelID,
                ),
            )
        }

        return result ?: throw ProviderServiceError.EmptyResponse
    }

    private fun latestUserPrompt(messages: List<ChatMessage>): String? {
        return messages
            .asReversed()
            .firstOrNull { it.role == ai.oriveo.community.core.model.ChatRole.User }
            ?.text
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }

    private fun streamViaChatCompletions(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        resolved: MetadataClient.ResolvedModelMetadata?,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        val url = resolveUrl(baseUrl)
        val requestBody = buildChatBody(
            modelID = modelID,
            messages = messages,
            stream = true,
            reasoningMode = reasoningMode,
            supportsImageGen = supportsImageGen,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
            resolved = resolved,
        )

        // A deterministic upstream 400 saying "parameter X is not supported" triggers one retry
        // with that parameter stripped. This self-heal net also covers custom OpenAI-compatible
        // endpoints.
        UnsupportedParamRetry.run(
            ProviderKind.OpenAI,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = chatSelfHealIdentity(modelID, requestOptions, url),
        ) { requestBodyAttempt ->
        val statement = client.preparePost("$url/chat/completions") {
            applyHeaders(apiKey)
            contentType(ContentType.Application.Json)
            setBody(requestBodyAttempt)
        }

        statement.execute { response ->
            if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

            var accumulatedText = ""
            var lastUsage: Usage? = null
            val nativeToolParser = NativeToolCallParser(NativeToolProtocol.OpenAIChat)

            SseParser.parseOpenAICompatibleMulti(
                response = response,
                json = json,
                onChunk = { payload ->
                    val events = mutableListOf<StreamEvent>()
                    runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()?.let { root ->
                        nativeToolParser.parse(null, root).takeIf { it.isNotEmpty() }?.let {
                            events += StreamEvent.ToolCallDeltas(it)
                        }
                    }
                    val chunk = json.decodeFromString<StreamChunk>(payload)
                    chunk.usage?.let { lastUsage = it }
                    val delta = chunk.choices?.firstOrNull()?.delta?.content
                    if (!delta.isNullOrEmpty()) {
                        accumulatedText += delta
                        events += StreamEvent.Delta(delta)
                    }
                    events
                },
                onDone = {
                    val breakdown = usageBreakdown(lastUsage)
                    StreamEvent.Done(
                        buildResult(
                            text = accumulatedText.trim(),
                            breakdown = breakdown,
                            modelID = modelID,
                        ),
                    )
                },
            ).collect { emit(it) }
        }
        }
    }

    private fun isResponsesNotSupported(statusCode: Int): Boolean {
        return statusCode == 404
    }

    private fun mapHttpError(statusCode: Int, body: String): ProviderServiceError =
        SseParser.mapHttpError(statusCode, body)

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
    private data class ChunkDelta(val content: String? = null)

    @Serializable
    private data class Usage(
        val prompt_tokens: Int = 0,
        val completion_tokens: Int = 0,
        val prompt_tokens_details: UsagePromptDetails? = null,
        val completion_tokens_details: UsageCompletionDetails? = null,
    )

    @Serializable
    private data class UsagePromptDetails(val cached_tokens: Int? = null)

    @Serializable
    private data class UsageCompletionDetails(val reasoning_tokens: Int? = null)

    /**
     * Unified OpenAI usage breakdown, supporting both the Chat Completions and the Responses
     * shapes. The Responses API names its fields `input_tokens` / `output_tokens` while Chat uses
     * `prompt_tokens` / `completion_tokens`; in both, the cached and reasoning sub-fields sit at
     * `*_details.cached_tokens` and `*_details.reasoning_tokens`.
     */
    private fun usageBreakdown(usage: Usage?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val cached = usage.prompt_tokens_details?.cached_tokens ?: 0
        val reasoning = usage.completion_tokens_details?.reasoning_tokens ?: 0
        return UsageBreakdown(
            promptTokens = (usage.prompt_tokens - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = usage.completion_tokens,
            reasoningTokens = reasoning,
            cacheReadObserved = usage.prompt_tokens_details?.cached_tokens != null,
        )
    }

    private fun responsesUsageBreakdown(usage: ResponsesUsage?): UsageBreakdown {
        if (usage == null) return UsageBreakdown()
        val cached = usage.input_tokens_details?.cached_tokens ?: 0
        val reasoning = usage.output_tokens_details?.reasoning_tokens ?: 0
        val input = usage.input_tokens ?: 0
        return UsageBreakdown(
            promptTokens = (input - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = usage.output_tokens ?: 0,
            reasoningTokens = reasoning,
            cacheReadObserved = usage.input_tokens_details?.cached_tokens != null,
        )
    }

    private fun buildResult(
        text: String,
        attachments: List<Attachment>? = null,
        breakdown: UsageBreakdown,
        modelID: String,
    ): ProviderChatResult {
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.OpenAI)
        val (cost, source) = CostCalculator.calcCost(breakdown, resolved)
        return ProviderChatResult(
            text = text,
            promptTokens = breakdown.promptTokens + breakdown.cachedInputTokens,
            completionTokens = breakdown.completionTokens,
            estimatedCost = cost,
            attachments = attachments,
            cachedInputTokens = breakdown.reportedCachedInputTokens,
            costSource = source.name,
        )
    }

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
                    ?.mapNotNull { part ->
                        if (part.type == "output_text") part.text else null
                    }
                    ?.joinToString("")
                    .orEmpty()
            }

        val resolvedAttachments: List<Attachment>
            get() {
                val attachments = mutableListOf<Attachment>()
                fun buildImageAttachment(base64: String) = Attachment(
                    id = java.util.UUID.randomUUID().toString(),
                    kind = AttachmentKind.Image,
                    fileName = "generated_image.png",
                    mimeType = "image/png",
                    base64Data = base64,
                )
                for (item in output.orEmpty()) {
                    if (item.type == "image_generation_call" && !item.result.isNullOrBlank()) {
                        attachments += buildImageAttachment(item.result)
                    }
                    for (part in item.content.orEmpty()) {
                        if (part.type == "output_image" && !part.result.isNullOrBlank()) {
                            attachments += buildImageAttachment(part.result)
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
    private data class ResponsesInputDetails(
        // Responses API: cache reads live in cached_tokens, with the same meaning as in chat
        // completions.
        val cached_tokens: Int? = null,
    )

    @Serializable
    private data class ResponsesOutputDetails(
        val reasoning_tokens: Int? = null,
    )

    @Serializable
    private data class ResponsesStreamDelta(val delta: String? = null)

    @Serializable
    private data class ResponsesStreamCompleted(
        val usage: ResponsesUsage? = null,
        val response: ResponsesCompletedResponse? = null,
    ) {
        val resolvedUsage: ResponsesUsage?
            get() = usage ?: response?.usage
    }

    @Serializable
    private data class ResponsesCompletedResponse(
        val id: String? = null,
        val usage: ResponsesUsage? = null,
    )

    @Serializable
    private data class ResponsesStreamImageDone(val result: String? = null)

    @Serializable
    private data class ImagesGenerationResponse(
        val data: List<ImageData> = emptyList(),
        val usage: ResponsesUsage? = null,
    ) {
        val resolvedAttachments: List<Attachment>
            get() = data.mapNotNull { item ->
                val payload = item.b64_json ?: item.url
                payload?.takeIf { it.isNotBlank() }?.let { encoded ->
                    Attachment(
                        id = java.util.UUID.randomUUID().toString(),
                        kind = AttachmentKind.Image,
                        fileName = "generated_image.png",
                        mimeType = "image/png",
                        base64Data = encoded,
                    )
                }
            }
    }

    @Serializable
    private data class ImageData(
        val b64_json: String? = null,
        val url: String? = null,
    )

    @Serializable
    private data class ErrorEnvelope(val error: ErrorBody? = null)

    @Serializable
    private data class ErrorBody(val message: String? = null)

}
