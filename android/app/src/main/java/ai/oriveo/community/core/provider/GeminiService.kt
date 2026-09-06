package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
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
import io.ktor.client.request.header
import io.ktor.client.request.parameter
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
import kotlinx.serialization.json.jsonObject
import java.util.UUID

/**
 * Gemini Service.
 *
 * Covers generateContent with streaming and image generation (inline data extraction),
 * the Google Search tool, reasoning mode mapped onto thinkingConfig.thinkingBudget, and
 * attachments carried as inlineData for images and PDFs.
 *
 * Transport wiring:
 *   - [transportRegistry] supplies the gemini_generate strategy
 *   - candidates[].groundingMetadata.groundingChunks[] is parsed during streaming to
 *     produce Citations
 *   - the mergeParams of profile.webSearch (gem_web or gem_web_retrieval) are injected
 *     into the request body
 */
class GeminiService(
    private val client: HttpClient,
    private val json: Json,
    private val transportRegistry: TransportRegistry,
) : ProviderService {

    companion object {
        private const val BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
        // TransportKind is this module's historical internal key for a strategy, while
        // capabilityRuntime uses the canonical protocol name from the recipe contract. A
        // local enum drifting apart from that must never reject an otherwise valid recipe.
        private const val CAPABILITY_RUNTIME_TRANSPORT = "gemini_generate_content"

        // finishReason values that mean Gemini's content policy stopped the generation:
        // seeing one has to break the stream. Not throwing would hand a truncated or empty
        // reply to the caller as a Done, i.e. as a normal completion.
        // STOP / MAX_TOKENS / null are genuine completions and deliberately not in this set.
        private val BLOCKED_FINISH_REASONS = setOf(
            "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII",
        )
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
        val runtime = MetadataClient.capabilityRuntimeRequest(
            ProviderKind.Gemini, modelID, "gemini_interactions", webSearchEnabled, reasoningMode,
        )
        val recipe = runtime?.selections?.firstOrNull { it.capability == "web" && it.executionKind == "endpoint_route" }
        if (runtime != null && recipe != null) {
            var done: StreamEvent.Done? = null
            sendInteractionsStream(apiKey, modelID, messages, baseUrl, false, runtime.runtime, recipe, requestOptions)
                .collect { if (it is StreamEvent.Done) done = it }
            return done ?: throw ProviderServiceError.EmptyResponse
        }
        if (apiKey.isBlank() || modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing provider credentials.")
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Gemini)
        val body = buildGenerateBody(
            messages, modelID, supportsImageGen, reasoningMode, webSearchEnabled, requestOptions,
            resolved?.profiles?.webSearch, resolved?.profiles?.imageGen, resolved,
        )
        val response = client.post("${resolveBaseUrl(baseUrl)}/models/$modelID:generateContent") {
            header("x-goog-api-key", apiKey); contentType(ContentType.Application.Json); setBody(body)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val parsed = json.decodeFromString<GenerateResponse>(response.bodyAsText())
        throwIfBlockedChunk(parsed)
        val parts = parsed.candidates?.firstOrNull()?.content?.parts.orEmpty()
        val text = parts.filter { it.thought != true }.mapNotNull { it.text }.joinToString("").trim()
        if (text.isEmpty()) throw ProviderServiceError.EmptyResponse
        val usage = parsed.usageMetadata
        return StreamEvent.Done(ProviderChatResult(
            text = text,
            promptTokens = usage?.promptTokenCount ?: 0,
            completionTokens = (usage?.candidatesTokenCount ?: 0) + (usage?.thoughtsTokenCount ?: 0),
            reasoningText = parts.filter { it.thought == true }.mapNotNull { it.text }.joinToString("").takeIf { it.isNotEmpty() },
        ))
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

        // Interactions is only reachable through an exact endpoint_route recipe. Current server
        // verdicts intentionally select no such route, so ordinary Gemini remains generateContent.
        val interactionsRuntime = MetadataClient.capabilityRuntimeRequest(
            providerKind = ProviderKind.Gemini,
            modelID = modelID,
            finalTransport = "gemini_interactions",
            webRequested = webSearchEnabled,
            reasoningMode = reasoningMode,
        )
        val interactionsRecipe = interactionsRuntime?.selections?.firstOrNull {
            it.capability == "web" && it.executionKind == "endpoint_route"
        }
        if (interactionsRuntime != null && interactionsRecipe != null) {
            emitAll(
                sendInteractionsStream(
                    apiKey = apiKey,
                    modelID = modelID,
                    messages = messages,
                    baseUrl = baseUrl,
                    stream = true,
                    runtime = interactionsRuntime.runtime,
                    recipe = interactionsRecipe,
                    requestOptions = requestOptions,
                ),
            )
            return@flow
        }

        // gemini_generate strategy + streamShape
        val strategy = transportRegistry.strategy(TransportKind.GeminiGenerate)
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Gemini)
        val webProfileName = resolved?.profiles?.webSearch
        val shape = if (webSearchEnabled) {
            ai.oriveo.community.core.provider.transport.StreamShape.fromMetadata(
                MetadataClient.webSearchStreamShape(webProfileName)
            )
        } else null

        val requestBody = buildGenerateBody(
            messages,
            modelID = modelID,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
            webProfileName = webProfileName,
            imageGenProfileName = resolved?.profiles?.imageGen,
            resolved = resolved,
        )
        val continuationRecipe = capabilityRuntimeContinuationSelection(
            ProviderKind.Gemini, modelID, CAPABILITY_RUNTIME_TRANSPORT, webSearchEnabled, reasoningMode,
        )?.takeIf { it.continuationKind == "replay_blocks" }

        val streamUrl = "${resolveBaseUrl(baseUrl)}/models/$modelID:streamGenerateContent"

        // Sent exactly once. A deterministic upstream 400 that names an unsupported parameter is
        // surfaced with that name; nothing is dropped and resent behind the user's back.
        UnsupportedParamRetry.run(
            ProviderKind.Gemini,
            modelID,
            requestBody,
            requestOptions = requestOptions,
            identity = officialSelfHealIdentity(
                providerKind = ProviderKind.Gemini,
                modelID = modelID,
                options = requestOptions,
                finalTransport = TransportKind.GeminiGenerate.wireValue,
                finalUrl = streamUrl,
            ),
        ) { requestBodyAttempt ->
        val statement = client.preparePost(streamUrl) {
            header("Content-Type", "application/json")
            header("x-goog-api-key", apiKey)
            parameter("alt", "sse")
            contentType(ContentType.Application.Json)
            setBody(requestBodyAttempt)
        }

        requestOptions.capabilityExecutionCollector?.confirmDispatched()
        statement.execute { response ->
            if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

            var accumulatedText = ""
            var promptTokensTotal = 0   // includes cached
            var candidatesTokens = 0
            var thoughtsTokens = 0
            var cachedTokens = 0
            var cacheReadObserved = false
            val imageAttachments = mutableListOf<Attachment>()
            val continuationContents = mutableListOf<JsonElement>()
            val nativeToolParser = NativeToolCallParser(NativeToolProtocol.GeminiGenerate)

            SseParser.parseGeminiStreamMulti(
                response = response,
                json = json,
                onChunk = { payload ->
                    val events = mutableListOf<StreamEvent>()
                    val chunk = json.decodeFromString<GenerateResponse>(payload)
                    val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
                    if (root != null) {
                        nativeToolParser.parse(null, root).takeIf { it.isNotEmpty() }?.let {
                            events += StreamEvent.ToolCallDeltas(it)
                        }
                    }
                    if (continuationRecipe != null) {
                        val content = ((root?.get("candidates") as? JsonArray)?.firstOrNull() as? JsonObject)
                            ?.get("content") as? JsonObject
                        val signedParts = (content?.get("parts") as? JsonArray)?.filter { part ->
                            (part as? JsonObject)?.containsKey("thoughtSignature") == true
                        }.orEmpty()
                        if (signedParts.isNotEmpty()) {
                            continuationContents += JsonObject(content!!.toMutableMap().apply {
                                put("role", JsonPrimitive("model")); put("parts", JsonArray(signedParts))
                            })
                        }
                    }
                    // A policy-blocked finish has to throw so the error card appears; text
                    // already emitted is preserved by the Failed path above.
                    throwIfBlockedChunk(chunk)
                    chunk.usageMetadata?.let { u ->
                        promptTokensTotal = u.promptTokenCount ?: promptTokensTotal
                        candidatesTokens = u.candidatesTokenCount ?: candidatesTokens
                        thoughtsTokens = u.thoughtsTokenCount ?: thoughtsTokens
                        cachedTokens = u.cachedContentTokenCount ?: cachedTokens
                        cacheReadObserved = cacheReadObserved || u.cachedContentTokenCount != null
                    }

                    // Citation parsing (groundingMetadata.groundingChunks)
                    val cits = runCatching { strategy.parseCitations(payload, shape) }
                        .getOrNull()
                        .orEmpty()
                    if (cits.isNotEmpty()) events += StreamEvent.Citations(cits)

                    val parts = chunk.candidates?.firstOrNull()?.content?.parts
                    if (parts != null) {
                        // On Gemini 2.5+ thinking models part.thought=true marks reasoning
                        // rather than body text, so it is emitted as a separate Reasoning event.
                        val reasoningDelta = parts
                            .filter { it.thought == true }
                            .mapNotNull { it.text }
                            .joinToString("")
                        if (reasoningDelta.isNotEmpty()) {
                            events += StreamEvent.Reasoning(reasoningDelta)
                        }
                        val textDelta = parts
                            .filter { it.thought != true }
                            .mapNotNull { it.text }
                            .joinToString("")
                        // Collect inline image data.
                        parts.forEach { part ->
                            val inlineData = part.inlineData
                            if (inlineData != null && inlineData.mimeType.startsWith("image/")) {
                                imageAttachments.add(
                                    Attachment(
                                        id = UUID.randomUUID().toString(),
                                        kind = AttachmentKind.Image,
                                        fileName = "generated_image",
                                        mimeType = inlineData.mimeType,
                                        base64Data = inlineData.data,
                                    )
                                )
                            }
                        }

                        if (textDelta.isNotEmpty()) {
                            accumulatedText += textDelta
                            events += StreamEvent.Delta(textDelta)
                        }
                    }
                    events
                },
                onDone = {
                    // Gemini reports total = prompt + candidates + thoughts, three counts
                    // that are independent of each other (verified by measurement).
                    // promptTokens already includes cachedContent, so the cached part has to
                    // be subtracted to get the non-cached input.
                    val nonCachedPrompt = (promptTokensTotal - cachedTokens).coerceAtLeast(0)
                    val completion = candidatesTokens + thoughtsTokens
                    val breakdown = ai.oriveo.community.core.provider.UsageBreakdown(
                        promptTokens = nonCachedPrompt,
                        cachedInputTokens = cachedTokens,
                        completionTokens = completion,
                        reasoningTokens = thoughtsTokens,  // a subset of completion, for display only
                        cacheReadObserved = cacheReadObserved,
                    )
                    val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Gemini)
                    val (cost, source) = ai.oriveo.community.core.provider.CostCalculator.calcCost(breakdown, resolved)
                    StreamEvent.Done(
                        ProviderChatResult(
                            text = accumulatedText.trim(),
                            promptTokens = promptTokensTotal,
                            completionTokens = completion,
                            estimatedCost = cost,
                            attachments = imageAttachments.ifEmpty { null },
                            cachedInputTokens = breakdown.reportedCachedInputTokens,
                            costSource = source.name,
                        )
                    )
                },
            ).collect { event ->
                if (event is StreamEvent.Done && continuationRecipe != null && continuationContents.isNotEmpty()) {
                    emit(StreamEvent.RecipeContinuation(
                        "replay_blocks",
                        continuationRecipe.continuationVariant,
                        JsonObject(mapOf("blocks" to JsonArray(continuationContents.toList()))),
                    ))
                }
                emit(event)
            }
        }
        }
    }

    /**
     * baseURL resolution.
     * User configuration wins, then metadata.providers.gemini.transport.baseUrl, then the
     * built-in fallback. Gemini's endpoint is not a fixed path the way OpenAI's is - every
     * call joins `/models/{modelID}:streamGenerateContent` - so this only returns the
     * baseUrl + /v1beta form.
     */
    private fun resolveBaseUrl(custom: String?): String {
        if (!custom.isNullOrBlank()) return custom.trimEnd('/')
        val transport = MetadataClient.providerTransport(ProviderKind.Gemini)
        val base = transport?.baseUrl?.takeIf { it.isNotBlank() } ?: "https://generativelanguage.googleapis.com"
        val trimmed = base.trimEnd('/')
        return if (trimmed.endsWith("/v1beta") || trimmed.endsWith("/v1")) trimmed else "$trimmed/v1beta"
    }

    /**
     * Typed endpoint_route builder used by both the production-gated path and MockEngine tests.
     * The route fields are intentionally exact; a metadata typo fails before opening a socket.
     */
    internal fun buildInteractionsRequest(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        stream: Boolean,
        runtime: JsonObject,
        recipe: MetadataClient.CapabilityRecipeSelection,
        previousInteractionId: String? = null,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
    ): Pair<String, String> {
        if (apiKey.isBlank() || modelID.isBlank() || recipe.executionKind != "endpoint_route" ||
            recipe.providerKind != "gemini" || recipe.route?.string("protocol") != "gemini_interactions" ||
            recipe.route.string("endpointClass") != "interactions" ||
            recipe.route.string("requestMapper") != "gemini_interactions_v1" ||
            recipe.route.string("path") != "/v1/interactions"
        ) throw ProviderServiceError.InvalidConfiguration("Invalid Gemini Interactions recipe.")
        val outboundMessages = if (previousInteractionId.isNullOrBlank()) messages else {
            listOfNotNull(messages.lastOrNull { it.role.rawValue == "user" })
        }
        val base = buildJsonObject {
            put("model", JsonPrimitive(modelID))
            put("stream", JsonPrimitive(stream))
            put("input", JsonArray(outboundMessages.map { message ->
                buildJsonObject {
                    put("role", JsonPrimitive(if (message.role.rawValue == "assistant") "model" else "user"))
                    put("parts", JsonArray(listOf(buildJsonObject { put("text", JsonPrimitive(message.text)) })))
                }
            }))
            MessageBuilder.normalizeRequestOptions(requestOptions).systemPrompt.takeIf { it.isNotBlank() }?.let { prompt ->
                put("system_instruction", JsonPrimitive(prompt))
            }
        }
        val compilation = ProviderRecipeRequestCompiler.compile(
            runtime,
            ProviderRecipeRequestCompiler.Input(
                providerKind = recipe.providerKind,
                transport = "gemini_interactions",
                recipeRef = recipe.id,
                capability = "web",
                selectedIntent = recipe.selectedIntent,
                availableIntents = recipe.availableIntents,
                baseOwnedArrays = mapOf("tools" to emptyList()),
            ),
        )
        if (!compilation.accepted) throw ProviderServiceError.InvalidConfiguration("Gemini Interactions recipe rejected: ${compilation.reason}")
        val body = JsonObject(base + (compilation.delta ?: JsonObject(emptyMap())) +
            listOfNotNull(previousInteractionId?.takeIf { it.isNotBlank() }?.let { "previous_interaction_id" to JsonPrimitive(it) }).toMap())
        val normalizedBase = resolveBaseUrl(baseUrl).removeSuffix("/v1beta").removeSuffix("/v1")
        return "$normalizedBase/v1/interactions" to body.toString()
    }

    private fun sendInteractionsStream(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        stream: Boolean,
        runtime: JsonObject,
        recipe: MetadataClient.CapabilityRecipeSelection,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        val previousId = if (requestOptions.localContinuationExplicit) {
            requestOptions.localContinuationState?.get("previousResponseId")?.let { (it as? JsonPrimitive)?.contentOrNull }
        } else null
        val (url, body) = buildInteractionsRequest(apiKey, modelID, messages, baseUrl, stream, runtime, recipe, previousId, requestOptions)
        val statement = client.preparePost(url) {
            header("x-goog-api-key", apiKey)
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        statement.execute { response ->
            if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
            var text = ""
            var promptTokens = 0
            var completionTokens = 0
            fun consume(root: JsonObject): List<StreamEvent> {
                val interaction = root["interaction"] as? JsonObject ?: root
                val usage = interaction["usage"] as? JsonObject
                promptTokens = usage?.number("total_input_tokens") ?: promptTokens
                completionTokens = usage?.number("total_output_tokens") ?: completionTokens
                if (root.string("event_type") != "step.delta") return emptyList()
                val step = root["step"] as? JsonObject ?: return emptyList()
                if (step.string("type") != "model_output") return emptyList()
                val delta = step["delta"] ?: return emptyList()
                val chunks = delta.textValues("text")
                return chunks.filter { it.isNotEmpty() }.map { chunk ->
                    text += chunk
                    StreamEvent.Delta(chunk)
                }
            }
            if (!stream) {
                val root = runCatching { json.parseToJsonElement(response.bodyAsText()).jsonObject }.getOrNull()
                    ?: throw ProviderServiceError.Upstream(200, "Gemini Interactions response invalid.")
                val completed = (root["steps"] as? JsonArray).orEmpty().flatMap { step ->
                    val objectStep = step as? JsonObject
                    if (objectStep?.string("type") == "model_output") objectStep.textValues("content") else emptyList()
                }
                completed.forEach { chunk -> text += chunk; emit(StreamEvent.Delta(chunk)) }
                val usage = root["usage"] as? JsonObject
                promptTokens = usage?.number("total_input_tokens") ?: 0
                completionTokens = usage?.number("total_output_tokens") ?: 0
                if (root.string("status") == "completed") {
                    root.string("id")?.takeIf { it.isNotBlank() }?.let { id ->
                        emit(StreamEvent.RecipeContinuation("previous_id", state = JsonObject(mapOf("previousResponseId" to JsonPrimitive(id)))))
                    }
                }
                emit(StreamEvent.Done(ProviderChatResult(text = text.trim(), promptTokens = promptTokens, completionTokens = completionTokens)))
                return@execute
            }
            SseParser.parseOpenAICompatibleMulti(
                response = response,
                json = json,
                onChunk = { payload ->
                    runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()?.let { root ->
                        val interaction = root["interaction"] as? JsonObject ?: root
                        val continuation = if (root.string("event_type") == "interaction.completed" ||
                            interaction.string("status") == "completed"
                        ) {
                            interaction.string("id")?.takeIf { it.isNotBlank() }?.let { id ->
                                StreamEvent.RecipeContinuation("previous_id", state = JsonObject(mapOf("previousResponseId" to JsonPrimitive(id))))
                            }
                        } else null
                        listOfNotNull(continuation) + consume(root)
                    }.orEmpty()
                },
                onDone = { StreamEvent.Done(ProviderChatResult(text = text.trim(), promptTokens = promptTokens, completionTokens = completionTokens)) },
            ).collect { emit(it) }
        }
    }

    private fun JsonObject?.string(key: String): String? = this?.get(key)?.let { (it as? JsonPrimitive)?.contentOrNull }
    private fun JsonObject.number(key: String): Int? = (this[key] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()
    private fun JsonElement?.textValues(key: String): List<String> = when (this) {
        is JsonObject -> when (val value = this[key]) {
            is JsonPrimitive -> value.contentOrNull?.let(::listOf).orEmpty()
            is JsonArray -> value.mapNotNull { (it as? JsonObject)?.get("text")?.let { text -> (text as? JsonPrimitive)?.contentOrNull } }
            else -> emptyList()
        }
        else -> emptyList()
    }

    private fun buildGenerateBody(
        messages: List<ChatMessage>,
        modelID: String,
        supportsImageGen: Boolean,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
        requestOptions: ChatRequestOptions,
        webProfileName: String?,
        imageGenProfileName: String?,
        resolved: MetadataClient.ResolvedModelMetadata?,
    ): String {
        val capabilityProjection = officialRequestCapabilityProjection(
            ProviderKind.Gemini, modelID, requestOptions, reasoningMode, webSearchEnabled, messages,
            finalTransport = TransportKind.GeminiGenerate.wireValue,
            runtimeTransport = CAPABILITY_RUNTIME_TRANSPORT,
        )
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        // Resolve the model for AttachmentRouter; with pdfNativeDefault=true every PDF goes
        // through the native path.
        val activeModel = MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.Gemini)
        // Build the Gemini contents, attachments included, through MessageBuilder.
        val contents = MessageBuilder.buildGeminiContents(messagesForCapabilityProjection(messages, capabilityProjection), activeModel)

        val sections = mutableListOf<String>()
        sections.add(""""contents":[$contents]""")
        MessageBuilder.geminiSystemInstructionJson(options.systemPrompt)?.let { sections.add(it) }

        // generationConfig
        val genConfigs = mutableListOf<String>()
        if (supportsImageGen) {
            genConfigs.add(""""responseModalities":["TEXT","IMAGE"]""")
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/temperature")) {
            MessageBuilder.temperatureJson(options.temperature)?.let { genConfigs.add(it) }
        }
        if (capabilityProjection.permitsOutbound("generation_parameter/max_tokens") ||
            capabilityProjection.permitsOutbound("generation_parameter/max_output_tokens")) {
            MessageBuilder.maxTokensJson(options.maxTokens, key = "maxOutputTokens")?.let { genConfigs.add(it) }
        }
        if (genConfigs.isNotEmpty()) {
            sections.add(""""generationConfig":{${genConfigs.joinToString(",")}}""")
        }

        var baseJson = "{${sections.joinToString(",")}}"
        if (supportsImageGen && !imageGenProfileName.isNullOrBlank()) {
            baseJson = mergeParamsIntoBody(baseJson, MetadataClient.imageGenMergeParams(imageGenProfileName))
        }
        val runtime = applyCapabilityRuntimeRecipes(
            bodyJson = baseJson,
            providerKind = ProviderKind.Gemini,
            modelID = modelID,
            finalTransport = CAPABILITY_RUNTIME_TRANSPORT,
            webRequested = webSearchEnabled,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions,
        )
        baseJson = runtime.body
        if (!runtime.authoritativeRuntime && webSearchEnabled && capabilityProjection.permitsOutbound("web_search") && !webProfileName.isNullOrBlank()) {
            // Inject the mergeParams of profile.webSearch:
            //   - gem_web: tools=[{google_search: {}}] (Gemini 2.0+)
            //   - gem_web_retrieval: tools=[{google_search_retrieval: {dynamic_retrieval_config:{...}}}] (1.5)
            val mergeParams = MetadataClient.webSearchMergeParams(webProfileName)
            val baseObj = parseJsonObjectOrNull(baseJson)
            if (mergeParams != null && baseObj != null) {
                val merged = applyProfileMergeParams(
                    baseBody = baseObj,
                    profileName = webProfileName,
                    mergeParams = mergeParams,
                )
                baseJson = merged.toString()
            }
        }

        if (!runtime.authoritativeRuntime) {
            val effectiveReasoning = effectiveReasoningMode(resolved, reasoningMode)
            baseJson = mergeParamsIntoBody(baseJson, reasoningMergeParams(resolved, reasoningMode).takeIf {
                reasoningMode == ReasoningMode.Automatic || capabilityProjection.permitsOutbound("reasoning_level/${effectiveReasoning.rawValue}")
            })
        }
        // Last step of generation parameter injection: every wire name in the
        // gemini_generate_content template sits nested under generationConfig.*, and not a
        // single same-named field may appear at the top level or generateContent returns 400.
        val generated = GenerationParameterResolver.apply(
            baseJson,
            requestOptions,
            resolved,
            capabilityProjection,
        )
        return applyCapabilityRuntimeCustomFragment(
            generated, ProviderKind.Gemini, modelID, CAPABILITY_RUNTIME_TRANSPORT, requestOptions,
        )
    }

    /**
     * Gemini signals a block through fields inside a 2xx stream rather than an HTTP error:
     *   - promptFeedback.blockReason: the prompt was rejected outright, usually with no
     *     candidates at all and zero output for the whole stream;
     *   - candidates[].finishReason in [BLOCKED_FINISH_REASONS]: generation was cut off
     *     part-way by content policy.
     * Throwing on neither leaves the user staring at an empty or truncated reply with no
     * way to retry.
     * Upstream(200) is the type used, matching how SseParser reports in-stream errors: the
     * stream already came back 2xx, so there is no finer HTTP status to report.
     */
    private fun throwIfBlockedChunk(chunk: GenerateResponse) {
        chunk.promptFeedback?.blockReason?.takeIf { it.isNotBlank() }?.let { reason ->
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini blocked the prompt (blockReason=$reason).",
            )
        }
        val finishReason = chunk.candidates?.firstOrNull()?.finishReason
        if (finishReason != null && finishReason in BLOCKED_FINISH_REASONS) {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini stopped the response (finishReason=$finishReason).",
            )
        }
    }

    // --- API Types ---

    @Serializable private data class GenerateResponse(
        val candidates: List<Candidate>? = null,
        val usageMetadata: UsageMeta? = null,
        val promptFeedback: PromptFeedback? = null,
    )
    @Serializable private data class PromptFeedback(val blockReason: String? = null)
    @Serializable private data class Candidate(
        val content: CandidateContent? = null,
        val finishReason: String? = null,
    )
    @Serializable private data class CandidateContent(val parts: List<Part>? = null)
    @Serializable private data class Part(
        val text: String? = null,
        val inlineData: InlineData? = null,
        // Gemini 2.5+ thinking models flag a part with `thought: true` to say the text is
        // reasoning. It must not be delivered as a body Delta, or reasoning text bleeds
        // into the answer.
        val thought: Boolean? = null,
    )
    @Serializable private data class InlineData(
        val mimeType: String,
        val data: String,
    )
    @Serializable private data class UsageMeta(
        val promptTokenCount: Int? = null,
        val candidatesTokenCount: Int? = null,
        // Measured against the live API: candidates does NOT include thoughts, so the two
        // have to be added together to get the real completion count.
        val thoughtsTokenCount: Int? = null,
        val cachedContentTokenCount: Int? = null,
    )
}
