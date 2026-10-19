package ai.oriveo.community.core.provider

import ai.oriveo.community.core.context.StopFamily
import ai.oriveo.community.core.context.StreamEnding
import ai.oriveo.community.core.context.StreamFinish
import ai.oriveo.community.core.context.StreamFinishTracker
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.attachments.ImageMediaType
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.applyProfileMergeParams
import ai.oriveo.community.core.provider.transport.deepMergeJsonObject
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
import kotlinx.serialization.json.booleanOrNull
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

        /** Allowlist of the Interactions route.path (the path comes from the recipe). */
        private val INTERACTIONS_PATHS = setOf("/v1/interactions", "/v1beta/interactions")

        /**
         * Whether this request switches to Interactions: only when the server recipe selects an endpoint_route for
         * web search and the request history (including the current turn) has no video attachment (the first Interactions
         * version does not accept video, so video stays on generateContent and is delivered as inlineData).
         * Outbound dispatch and the pre-send route resolution share this one place, and the recipe itself
         * is returned for the outbound path to use.
         */
        internal fun interactionsRoute(
            modelID: String,
            webSearchEnabled: Boolean,
            reasoningMode: ReasoningMode,
            historyHasVideo: Boolean,
        ): Pair<MetadataClient.CapabilityRuntimeRequest, MetadataClient.CapabilityRecipeSelection>? {
            if (historyHasVideo) return null
            // Only selectable when the Server judges the model's transport to be gemini_interactions (the same rule as the Server verdict and Web).
            val modelTransport = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Gemini)?.transport
            if (TransportKind.fromWireValue(modelTransport) != TransportKind.GeminiInteractions) return null
            val runtime = MetadataClient.capabilityRuntimeRequest(
                providerKind = ProviderKind.Gemini,
                modelID = modelID,
                finalTransport = "gemini_interactions",
                webRequested = webSearchEnabled,
                reasoningMode = reasoningMode,
                includeAutomaticReasoning = true,
            ) ?: return null
            val recipe = runtime.selections.firstOrNull {
                it.capability == "web" && it.executionKind == "endpoint_route"
            } ?: return null
            return runtime to recipe
        }

        /** The video condition [interactionsRoute] uses in outbound dispatch: any message in the whole request history carries a video attachment. */
        internal fun hasVideoAttachment(messages: List<ChatMessage>): Boolean =
            messages.any { message -> message.attachments.orEmpty().any { it.kind == AttachmentKind.Video } }

        /**
         * The reasoning recipe selected for this request on the Interactions route (the transport was already matched exactly by capabilityRuntimeRequest).
         * The automatic tier is selected too (selectedIntent=null), and the builder writes only the base op that has no intent.
         */
        private fun interactionsReasoningRecipe(
            runtime: MetadataClient.CapabilityRuntimeRequest,
        ): MetadataClient.CapabilityRecipeSelection? = runtime.selections.firstOrNull {
            it.capability == "reasoning" && it.executionKind == "request_overlay"
        }

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
        val interactions = interactionsRoute(modelID, webSearchEnabled, reasoningMode, hasVideoAttachment(messages))
        val runtime = interactions?.first
        val recipe = interactions?.second
        if (runtime != null && recipe != null) {
            var done: StreamEvent.Done? = null
            sendInteractionsStream(
                apiKey, modelID, messages, baseUrl, false, runtime.runtime, recipe,
                interactionsReasoningRecipe(runtime), requestOptions,
            )
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
        val rawText = parts.filter { it.thought != true }.mapNotNull { it.text }.joinToString("")
        val text = rawText.trim()
        if (text.isEmpty()) throw ProviderServiceError.EmptyResponse
        val usage = parsed.usageMetadata
        return StreamEvent.Done(ProviderChatResult(
            text = text,
            rawText = rawText,
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

        // Interactions is only reachable through an exact endpoint_route recipe. Default server
        // verdicts select no such route (only an Admin transport override does), so ordinary
        // Gemini remains generateContent.
        val interactions = interactionsRoute(modelID, webSearchEnabled, reasoningMode, hasVideoAttachment(messages))
        val interactionsRuntime = interactions?.first
        val interactionsRecipe = interactions?.second
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
                    reasoningRecipe = interactionsReasoningRecipe(interactionsRuntime),
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
                stopFamily = StopFamily.GEMINI,
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

    /** Attachment stage: PreActivation in production; Activated is passed only by tests, and is promoted only after a real provider verifies it. */
    internal enum class InteractionsAttachmentStage { PreActivation, Activated }

    /**
     * Interactions request body (shared golden gemini_interactions.request-golden.v1.json).
     * The path is read only from the route.path the Server delivers, and anything outside the allowlist is a configuration error;
     * every turn sends the full Step[] and always carries store:false, with no previous_interaction_id continuation.
     * All thinking values come from the reasoning recipe; the client hard-codes none.
     */
    internal fun buildInteractionsRequest(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        stream: Boolean,
        runtime: JsonObject,
        route: JsonObject?,
        webRecipe: MetadataClient.CapabilityRecipeSelection?,
        reasoningRecipe: MetadataClient.CapabilityRecipeSelection?,
        reasoningIntent: String?,
        attachmentStage: InteractionsAttachmentStage = InteractionsAttachmentStage.PreActivation,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
    ): Pair<String, String> {
        val path = route?.string("path")
        if (apiKey.isBlank() || modelID.isBlank() || route?.string("protocol") != "gemini_interactions" ||
            route.string("endpointClass") != "interactions" ||
            route.string("requestMapper") != "gemini_interactions_v1" ||
            path !in INTERACTIONS_PATHS ||
            (webRecipe != null && (webRecipe.executionKind != "endpoint_route" || webRecipe.providerKind != "gemini"))
        ) throw ProviderServiceError.InvalidConfiguration("Invalid Gemini Interactions recipe.")
        val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
        val steps = messages.mapIndexedNotNull { index, message ->
            // An assistant turn with an empty body (nothing was written after a failure or interruption) is not replayed; the user turns around it each become a step.
            if (message.role == ChatRole.Assistant && message.text.isBlank()) {
                null
            } else if (message.role == ChatRole.Assistant) {
                // In the first version an assistant turn replays only its body, not thinking or signatures.
                interactionsStep("model_output", listOf(interactionsText(message.text)))
            } else {
                interactionsStep(
                    "user_input",
                    interactionsUserContent(message, isCurrentTurn = index == currentTurnIndex, attachmentStage, requestOptions),
                )
            }
        }
        val base = buildJsonObject {
            put("model", JsonPrimitive(modelID))
            put("input", JsonArray(steps))
            MessageBuilder.normalizeRequestOptions(requestOptions).systemPrompt.takeIf { it.isNotBlank() }?.let { prompt ->
                put("system_instruction", JsonPrimitive(prompt))
            }
            put("stream", JsonPrimitive(stream))
            put("store", JsonPrimitive(false))
        }
        var delta = JsonObject(emptyMap())
        webRecipe?.let { recipe ->
            delta = deepMergeJsonObject(delta, compileInteractionsRecipe(runtime, recipe, "web", recipe.selectedIntent))
        }
        // The automatic tier (intent=null) is also compiled with selectedIntent=null, and only the base op without an intent is written.
        reasoningRecipe?.let { recipe ->
            delta = deepMergeJsonObject(delta, compileInteractionsRecipe(runtime, recipe, "reasoning", reasoningIntent))
        }
        val body = deepMergeJsonObject(base, delta)
        val normalizedBase = resolveBaseUrl(baseUrl).removeSuffix("/v1beta").removeSuffix("/v1")
        return "$normalizedBase$path" to body.toString()
    }

    private fun compileInteractionsRecipe(
        runtime: JsonObject,
        recipe: MetadataClient.CapabilityRecipeSelection,
        capability: String,
        intent: String?,
    ): JsonObject {
        val compilation = ProviderRecipeRequestCompiler.compile(
            runtime,
            ProviderRecipeRequestCompiler.Input(
                providerKind = recipe.providerKind,
                transport = "gemini_interactions",
                recipeRef = recipe.id,
                capability = capability,
                selectedIntent = intent,
                availableIntents = recipe.availableIntents,
                baseOwnedArrays = mapOf("tools" to emptyList()),
            ),
        )
        if (!compilation.accepted) throw ProviderServiceError.InvalidConfiguration("Gemini Interactions recipe rejected: ${compilation.reason}")
        return compilation.delta ?: JsonObject(emptyMap())
    }

    /**
     * The text of one turn comes first and the media after it. PreActivation: images get a placeholder and files are injected as text
     * through xml-v1, so no media enters the body; Activated: typed image / document (passed only by tests).
     */
    private fun interactionsUserContent(
        message: ChatMessage,
        isCurrentTurn: Boolean,
        stage: InteractionsAttachmentStage,
        requestOptions: ChatRequestOptions,
    ): List<JsonObject> {
        val attachments = message.attachments.orEmpty()
        return when (stage) {
            InteractionsAttachmentStage.PreActivation -> {
                val plan = AttachmentDelivery.plan(
                    baseText = MessageBuilder.withImagePlaceholders(
                        message.text,
                        attachments,
                        AttachmentTransportProfile.GeminiInteractions.imagePlaceholderText,
                    ),
                    attachments = attachments,
                    model = requestOptions.activeModel,
                    transport = AttachmentTransportProfile.GeminiInteractions,
                )
                AttachmentDelivery.requireDeliverable(plan, isCurrentTurn)
                listOf(interactionsText(plan.text))
            }
            InteractionsAttachmentStage.Activated -> {
                val media = attachments.mapNotNull { attachment ->
                    when (attachment.kind) {
                        AttachmentKind.Image -> (attachment.base64Data ?: attachment.thumbnailBase64)
                            ?.let { interactionsMedia("image", it, ImageMediaType.resolve(it, attachment.mimeType)) }
                        AttachmentKind.File -> (attachment.originalBase64Data ?: attachment.base64Data)
                            ?.let { interactionsMedia("document", it, attachment.mimeType) }
                        AttachmentKind.Video -> null
                    }
                }
                listOfNotNull(interactionsText(message.text).takeIf { message.text.isNotBlank() || media.isEmpty() }) + media
            }
        }
    }

    private fun interactionsStep(type: String, content: List<JsonObject>) = buildJsonObject {
        put("type", JsonPrimitive(type))
        put("content", JsonArray(content))
    }

    private fun interactionsText(text: String) = buildJsonObject {
        put("type", JsonPrimitive("text"))
        put("text", JsonPrimitive(text))
    }

    private fun interactionsMedia(type: String, data: String, mimeType: String) = buildJsonObject {
        put("type", JsonPrimitive(type))
        put("data", JsonPrimitive(data))
        put("mime_type", JsonPrimitive(mimeType))
    }

    /**
     * Frame-by-frame parsing and terminal-state decision of the Interactions stream (shared fixture recorded/gemini_interactions.expected.json);
     * the production streaming path and the fixture replay share this one. data.event_type decides, and for step.delta the delta sits at the top level of the frame.
     */
    internal class InteractionsStreamParser {
        enum class Terminal(val wire: String) {
            Completed("completed"), Incomplete("incomplete"), Error("error"), Interrupted("interrupted"),
        }
        data class ErrorInfo(val code: String?, val message: String?, val phase: String)
        /** A null [cachedTokens] means upstream reported no cache (which is not the same as 0). */
        data class Usage(val inputTokens: Int, val outputTokens: Int, val thoughtTokens: Int, val cachedTokens: Int? = null)

        var text = ""
            private set
        var error: ErrorInfo? = null
            private set
        var usage: Usage? = null
            private set
        var terminal: Terminal? = null
            private set
        private var thinking = ""
        private var searchEvidenceIndex = 0

        fun consume(root: JsonObject): List<StreamEvent> = when (root.str("event_type")) {
            "step.delta" -> (root["delta"] as? JsonObject)?.let(::delta).orEmpty()
            "interaction.completed" -> {
                completed(root["interaction"] as? JsonObject)
                emptyList()
            }
            "error" -> {
                val payload = root["error"] as? JsonObject
                fail(payload?.str("code"), payload?.str("message"), streamErrorFrame = true)
            }
            // interaction.created / status_update / step.start / step.stop / unknown types: they do not affect the body or the terminal state.
            else -> emptyList()
        }

        /** Non-streaming Interaction resource: the body of the model_output steps. The terminal state and usage are then decided by [complete]. */
        fun outputOf(interaction: JsonObject): List<StreamEvent> =
            (interaction["steps"] as? JsonArray).orEmpty().flatMap { step ->
                val objectStep = step as? JsonObject
                if (objectStep?.str("type") != "model_output") return@flatMap emptyList()
                (objectStep["content"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                    .filter { it.str("type") == null || it.str("type") == "text" }
                    .flatMap { content ->
                        delta(JsonObject(mapOf("type" to JsonPrimitive("text"), "text" to (content["text"] ?: JsonPrimitive("")))))
                    }
            }

        /** Non-streaming and streaming interaction.completed share the same terminal-state / usage decision. */
        fun complete(interaction: JsonObject) = completed(interaction)

        /** Called when the stream ends: with neither completed nor error it was interrupted, and is handled as an error. */
        fun finish(): Terminal = terminal
            ?: fail(
                "interaction_stream_closed", null, streamErrorFrame = false, outcome = Terminal.Interrupted,
                // The stream closed without interaction.completed: EOF type
                streamFinish = StreamFinish(StopFamily.GEMINI_INTERACTIONS, StreamEnding.EOF_WITHOUT_MARKER),
            )

        /** The finish carried by Done when interaction.completed (completed / incomplete) arrives; finishRaw is the interaction status. */
        var terminalStatus: String? = null
            private set

        private fun delta(delta: JsonObject): List<StreamEvent> = when (delta.str("type")) {
            "text" -> delta.str("text").orEmpty().takeIf { it.isNotEmpty() }?.let { chunk ->
                text += chunk
                listOf(StreamEvent.Delta(chunk))
            }.orEmpty()
            "thought_summary" -> (delta["content"] as? JsonObject)?.str("text").orEmpty().takeIf { it.isNotEmpty() }?.let { chunk ->
                thinking += chunk
                listOf(StreamEvent.Reasoning(chunk))
            }.orEmpty()
            "text_annotation_delta" -> {
                val citations = (delta["annotations"] as? JsonArray).orEmpty().mapNotNull { element ->
                    val annotation = element as? JsonObject ?: return@mapNotNull null
                    if (annotation.str("type") != "url_citation") return@mapNotNull null
                    val url = annotation.str("url")?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
                    Citation(
                        url = url,
                        title = annotation.str("title")?.takeIf { it.isNotBlank() },
                        startIndex = annotation.int("start_index"),
                        endIndex = annotation.int("end_index"),
                    )
                }
                if (citations.isEmpty()) emptyList() else listOf(StreamEvent.Citations(citations))
            }
            // The official stream sample carries no result; a search counts as executed whenever is_error is not true.
            "google_search_result" -> if ((delta["is_error"] as? JsonPrimitive)?.booleanOrNull == true) emptyList() else {
                val count = (delta["result"] as? JsonArray)?.size ?: 0
                listOf(StreamEvent.ToolResult("google_search", "results=$count", searchEvidenceIndex++))
            }
            // thought_signature / google_search_call / unknown types: they enter neither the body, the thinking, nor the evidence.
            else -> emptyList()
        }

        private fun completed(interaction: JsonObject?) {
            when (interaction?.str("status")) {
                "completed" -> { terminal = Terminal.Completed; terminalStatus = "completed"; usage = usageOf(interaction) }
                "incomplete" -> { terminal = Terminal.Incomplete; terminalStatus = "incomplete"; usage = usageOf(interaction) }
                "failed" -> fail(
                    "interaction_failed", null, streamErrorFrame = false,
                    streamFinish = StreamFinishTracker.geminiInteractionsFinish("failed"),
                )
                // This route sends no client tools, so requires_action counts as a failure.
                "requires_action" -> fail(
                    "interaction_requires_action", null, streamErrorFrame = false,
                    streamFinish = StreamFinishTracker.geminiInteractionsFinish("requires_action"),
                )
                "cancelled" -> fail(
                    "interaction_cancelled", null, streamErrorFrame = false, outcome = Terminal.Interrupted,
                    streamFinish = StreamFinishTracker.geminiInteractionsFinish("cancelled"),
                )
            }
        }

        private fun fail(
            code: String?,
            message: String?,
            streamErrorFrame: Boolean,
            outcome: Terminal = Terminal.Error,
            streamFinish: StreamFinish? = null,
        ): Nothing {
            val phase = if (text.isEmpty() && thinking.isEmpty()) "before_content" else "after_content"
            error = ErrorInfo(code, message, phase)
            terminal = outcome
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini Interactions stream reported an error (code=${code ?: "unknown"})" +
                    (message?.let { ": $it" } ?: "."),
                streamErrorFrame = streamErrorFrame,
                streamFinish = streamFinish,
            ).also { it.telemetryUpstreamErrorType = code?.takeIf { streamErrorFrame } }
        }

        private fun usageOf(interaction: JsonObject): Usage? = (interaction["usage"] as? JsonObject)?.let {
            Usage(
                it.int("total_input_tokens") ?: 0,
                it.int("total_output_tokens") ?: 0,
                it.int("total_thought_tokens") ?: 0,
                it.int("total_cached_tokens"),
            )
        }

        private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
        private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()
    }

    private fun sendInteractionsStream(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        stream: Boolean,
        runtime: JsonObject,
        recipe: MetadataClient.CapabilityRecipeSelection,
        reasoningRecipe: MetadataClient.CapabilityRecipeSelection?,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        val (url, body) = buildInteractionsRequest(
            apiKey, modelID, messages, baseUrl, stream, runtime,
            route = recipe.route, webRecipe = recipe, reasoningRecipe = reasoningRecipe,
            reasoningIntent = reasoningRecipe?.selectedIntent, requestOptions = requestOptions,
        )
        val statement = client.preparePost(url) {
            header("x-goog-api-key", apiKey)
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        requestOptions.capabilityExecutionCollector?.let { collector ->
            collector.recordCompiled(
                owner = recipe.capability,
                evidenceSignals = recipe.responseEvidenceSignals,
                revision = recipe.runtimeRevision,
                recipeRef = recipe.id,
            )
            reasoningRecipe?.let { reasoning ->
                collector.recordCompiled(
                    owner = reasoning.capability,
                    evidenceSignals = reasoning.responseEvidenceSignals,
                    revision = reasoning.runtimeRevision,
                    recipeRef = reasoning.id,
                    // Even when the automatic tier compiled the base op, it does not count as requested.
                    includeExecutionFact = reasoning.selectedIntent != null,
                )
            }
            collector.confirmDispatched()
        }
        statement.execute { response ->
            if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
            val parser = InteractionsStreamParser()
            if (!stream) {
                val root = runCatching { json.parseToJsonElement(response.bodyAsText()).jsonObject }.getOrNull()
                    ?: throw ProviderServiceError.Upstream(200, "Gemini Interactions response invalid.")
                parser.outputOf(root).forEach { emit(it) }
                parser.complete(root)
                parser.finish()
                emit(interactionsDone(parser, modelID))
                return@execute
            }
            SseParser.parseOpenAICompatibleMulti(
                response = response,
                json = json,
                onChunk = { payload ->
                    runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()?.let(parser::consume).orEmpty()
                },
                onDone = {
                    // completed / incomplete are delivered as a normal finish (like MAX_TOKENS on generateContent);
                    // a stream cut off without a terminal state throws in finish(), and the content already received is kept by the caller's failure path.
                    parser.finish()
                    interactionsDone(parser, modelID)
                },
            ).collect { emit(it) }
        }
    }

    private fun interactionsDone(parser: InteractionsStreamParser, modelID: String): StreamEvent.Done {
        val usage = parser.usage
        // Same rule as generateContent: input includes the cache, billing splits non-cached from cached; thinking counts into output and is also recorded as reasoning.
        val cached = usage?.cachedTokens ?: 0
        val breakdown = UsageBreakdown(
            promptTokens = ((usage?.inputTokens ?: 0) - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = (usage?.outputTokens ?: 0) + (usage?.thoughtTokens ?: 0),
            reasoningTokens = usage?.thoughtTokens ?: 0,
            cacheReadObserved = usage?.cachedTokens != null,
        )
        val (cost, source) = CostCalculator.calcCost(
            breakdown, MetadataClient.resolveCatalogModel(modelID, ProviderKind.Gemini),
        )
        return StreamEvent.Done(
            ProviderChatResult(
                text = parser.text.trim(),
                rawText = parser.text,
                promptTokens = usage?.inputTokens ?: 0,
                completionTokens = breakdown.completionTokens,
                estimatedCost = cost,
                cachedInputTokens = breakdown.reportedCachedInputTokens,
                costSource = source.name,
            ),
            // Reaching here means interaction.completed was received (otherwise finish() already threw the EOF-type error)
            finish = StreamFinish(StopFamily.GEMINI_INTERACTIONS, StreamEnding.CLEAN, parser.terminalStatus),
        )
    }

    private fun JsonObject?.string(key: String): String? = this?.get(key)?.let { (it as? JsonPrimitive)?.contentOrNull }
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
                streamFinish = StreamFinishTracker.geminiPromptBlockedFinish(reason),
                inBandFailure = ai.oriveo.community.core.model.UpstreamInBandFailure.ContentFiltered,
            )
        }
        val finishReason = chunk.candidates?.firstOrNull()?.finishReason
        if (finishReason != null && finishReason in BLOCKED_FINISH_REASONS) {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = "Gemini stopped the response (finishReason=$finishReason).",
                streamFinish = StreamFinishTracker.geminiBlockedFinish(finishReason),
                inBandFailure = ai.oriveo.community.core.model.UpstreamInBandFailure.ContentFiltered,
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
