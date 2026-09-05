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
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID
import java.net.URI

/**
 * MiniMax Service - OpenAI-compatible, api.minimax.io
 * Model metadata comes from the published model catalog; only filtering happens locally.
 * Image generation (the image-* models) goes to the /v1/image_generation endpoint.
 */
class MiniMaxService(client: HttpClient, json: Json) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://api.minimax.io/v1",
    providerName = "MiniMax",
    providerKind = ProviderKind.MiniMax,
) {
    private data class AnthropicWebRoute(
        val selection: MetadataClient.CapabilityRecipeSelection,
        val runtime: JsonObject,
        val path: String,
        val authHeader: String,
        val headers: Map<String, String>,
    )

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
        MetadataClient.ensureInitialized()
        exactAnthropicWebRoute(modelID, webSearchEnabled, reasoningMode)?.let { route ->
            return sendAnthropicWebMessage(
                route, apiKey, modelID, messages, baseUrl, requestOptions,
            )
        }
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.MiniMax)
        // The imageGen profile route (minimax_image_generation, which points at the separate
        // /image_generation endpoint) is the only authority for image dispatch. Anything else
        // - text, another route, or a missing route - goes to the base class, which fails
        // loud on a missing or unknown route. That is why the real supportsImageGen must be
        // passed through to super here and never silently downgraded to false.
        if (!(supportsImageGen &&
                MetadataClient.imageGenRoute(resolved?.profiles?.imageGen) == "minimax_image_generation")
        ) {
            return super.sendMessage(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                baseUrl = baseUrl,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                requestOptions = requestOptions,
            )
        }

        val prompt = messages.lastOrNull { it.role.name == "User" }?.text?.trim()
        if (prompt.isNullOrBlank()) {
            throw ProviderServiceError.InvalidConfiguration("Image generation requires a text prompt.")
        }

        // Fields such as response_format and n come from the catalog's requestDefaults so
        // they can be corrected without a client release, rather than hard-coded here.
        val requestDefaults = MetadataClient.imageGenRequestDefaults(resolved?.profiles?.imageGen)
        val response = client.post("${resolveBaseUrl(baseUrl)}/image_generation") {
            applyHeaders(apiKey)
            contentType(ContentType.Application.Json)
            setBody(
                buildJsonObject {
                    put("model", modelID)
                    put("prompt", prompt)
                    requestDefaults?.forEach { (key, value) -> put(key, value) }
                }.toString()
            )
        }

        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)

        val payload = json.parseToJsonElement(response.bodyAsText()).jsonObject
        val attachments = payload["data"]?.jsonObject
            ?.get("image_base64")?.jsonArray
            ?.mapNotNull { item ->
                val base64 = item.jsonPrimitive.content.takeIf { it.isNotBlank() } ?: return@mapNotNull null
                Attachment(
                    id = UUID.randomUUID().toString(),
                    kind = AttachmentKind.Image,
                    fileName = "generated_image.png",
                    mimeType = "image/png",
                    base64Data = base64,
                )
            }
            ?: emptyList()

        if (attachments.isEmpty()) throw ProviderServiceError.EmptyResponse

        return StreamEvent.Done(
            ProviderChatResult(
                text = "",
                attachments = attachments,
            )
        )
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
        MetadataClient.ensureInitialized()
        val route = exactAnthropicWebRoute(modelID, webSearchEnabled, reasoningMode)
        if (route == null) {
            emitAll(super@MiniMaxService.sendMessageStream(
                apiKey, modelID, messages, baseUrl, supportsImageGen, reasoningMode,
                webSearchEnabled, requestOptions,
            ))
            return@flow
        }
        emitAll(sendAnthropicWebMessageStream(route, apiKey, modelID, messages, baseUrl, requestOptions))
    }

    private fun exactAnthropicWebRoute(
        modelID: String,
        webSearchEnabled: Boolean,
        reasoningMode: ReasoningMode,
    ): AnthropicWebRoute? {
        if (!webSearchEnabled) return null
        val request = MetadataClient.capabilityRuntimeRequest(
            ProviderKind.MiniMax, modelID, "openai_chat", webRequested = true, reasoningMode = reasoningMode,
        ) ?: return null
        val selection = request.selections.singleOrNull { it.capability == "web" } ?: return null
        val route = selection.route ?: return null
        fun string(key: String) = (route[key] as? JsonPrimitive)?.contentOrNull
        val headers = (route["headers"] as? JsonObject)?.mapNotNull { (key, value) ->
            (value as? JsonPrimitive)?.contentOrNull?.let { key to it }
        }?.toMap() ?: return null
        if (selection.id != "minimax.messages.web.v1" ||
            selection.executionKind != "endpoint_route" ||
            selection.responseParserKind != "minimax_anthropic_web_v1" ||
            selection.continuationKind != "replay_blocks" ||
            string("sourceProtocol") != "openai_chat" || string("protocol") != "anthropic_messages" ||
            string("endpointClass") != "messages" || string("method") != "POST" ||
            string("authMode") != "x_api_key" || string("authHeader") != "x-api-key" ||
            string("requestMapper") != "minimax_anthropic_messages_v1" ||
            headers != mapOf("Content-Type" to "application/json", "anthropic-version" to "2023-06-01")
        ) return null
        val path = string("path")?.takeIf { it == "/anthropic/v1/messages" } ?: return null
        return AnthropicWebRoute(selection, request.runtime, path, "x-api-key", headers)
    }

    private fun buildAnthropicWebBody(
        route: AnthropicWebRoute,
        modelID: String,
        messages: List<ChatMessage>,
        stream: Boolean,
        requestOptions: ChatRequestOptions,
    ): JsonObject? {
        val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.MiniMax)
        val messageArray = runCatching {
            json.parseToJsonElement("[${MessageBuilder.buildAnthropicMessages(messages, MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.MiniMax))}]") as JsonArray
        }.getOrNull() ?: return null
        var body = buildJsonObject {
            put("model", modelID)
            put("max_tokens", requestOptions.maxTokens ?: resolved?.maxOutputTokens ?: 8192)
            requestOptions.temperature?.let { put("temperature", it) }
            put("stream", stream)
            put("messages", messageArray)
            requestOptions.systemPrompt.trim().takeIf(String::isNotEmpty)?.let { put("system", it) }
        }
        val baseArrays = mapOf("tools" to body["tools"].asArrayItems())
        val compiled = ProviderRecipeRequestCompiler.compile(
            route.runtime,
            ProviderRecipeRequestCompiler.Input(
                providerKind = route.selection.providerKind,
                transport = "openai_chat",
                recipeRef = route.selection.id,
                capability = "web",
                selectedIntent = route.selection.selectedIntent,
                availableIntents = route.selection.availableIntents,
                baseOwnedArrays = baseArrays,
            ),
        )
        if (!compiled.accepted || compiled.delta == null) return null
        body = ai.oriveo.community.core.provider.transport.deepMergeJsonObject(body, compiled.delta)
        if (requestOptions.localContinuationExplicit && requestOptions.localContinuationState != null) {
            val mapped = ProviderRecipeExecution.continuation(
                kind = "replay_blocks", variant = route.selection.continuationVariant,
                protocol = "anthropic_messages", responseParserKind = "minimax_anthropic_web_v1",
                intent = ai.oriveo.community.core.model.RequestPreferenceResolver.ContinuationIntent(
                    kind = "replay_blocks", variant = route.selection.continuationVariant,
                    step = 1, state = requestOptions.localContinuationState,
                ),
            )
            if (mapped is ProviderRecipeExecution.ContinuationWire.Messages) {
                body = body.insertMiniMaxReplayBeforeNewestUser(mapped.append)
            }
        }
        return body
    }

    private fun sendAnthropicWebMessageStream(
        route: AnthropicWebRoute,
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
    ): Flow<StreamEvent> = flow {
        val body = buildAnthropicWebBody(route, modelID, messages, stream = true, requestOptions)
            ?: throw ProviderServiceError.InvalidConfiguration("Invalid MiniMax web-search recipe.")
        val url = miniMaxAlternateRouteURL(baseUrl, route.path)
        val statement = client.preparePost(url) {
            route.headers.forEach { (name, value) -> header(name, value) }
            header(route.authHeader, apiKey)
            setBody(body.toString())
        }
        requestOptions.capabilityExecutionCollector?.confirmDispatched()
        statement.execute { response ->
            if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
            val strategy = ai.oriveo.community.core.provider.transport.AnthropicMessagesStrategy(json)
            val shape = ai.oriveo.community.core.provider.transport.StreamShape(
                citationsBlockType = "web_search_tool_result",
                citationUrlField = "url", citationTitleField = "title", citationSnippetField = "content",
            )
            var text = ""
            var reasoning = ""
            var inputTokens = 0
            var outputTokens = 0
            val blocks = sortedMapOf<Int, JsonObject>()
            val partialInputs = mutableMapOf<Int, StringBuilder>()
            var replayStateValid = true
            val toolParser = NativeToolCallParser(NativeToolProtocol.AnthropicMessages)
            SseParser.parseAnthropicStreamMulti(response, json, onEvent = { eventType, data ->
                val events = mutableListOf<StreamEvent>()
                val root = runCatching { json.parseToJsonElement(data).jsonObject }.getOrNull()
                if (root != null) {
                    val deltas = toolParser.parse(eventType, root)
                    if (deltas.isNotEmpty()) events += StreamEvent.ToolCallDeltas(deltas)
                }
                if (eventType.startsWith("content_block")) {
                    strategy.parseCitations(data, shape).takeIf(List<*>::isNotEmpty)?.let { events += StreamEvent.Citations(it) }
                }
                val index = (root?.get("index") as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
                when (eventType) {
                    "message_start" -> inputTokens = (((root?.get("message") as? JsonObject)?.get("usage") as? JsonObject)?.get("input_tokens") as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
                    "content_block_start" -> {
                        val block = root?.get("content_block") as? JsonObject
                        if (block == null || !block.isValidMiniMaxAnthropicBlock(partial = true)) replayStateValid = false
                        else blocks[index] = block
                    }
                    "content_block_delta" -> {
                        val delta = root?.get("delta") as? JsonObject
                        when ((delta?.get("type") as? JsonPrimitive)?.contentOrNull) {
                            "text_delta" -> (delta["text"] as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotEmpty)?.let { text += it; events += StreamEvent.Delta(it) }
                            "thinking_delta" -> (delta["thinking"] as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotEmpty)?.let { reasoning += it; events += StreamEvent.Reasoning(it) }
                            "input_json_delta" -> (delta["partial_json"] as? JsonPrimitive)?.contentOrNull?.let { partialInputs.getOrPut(index, ::StringBuilder).append(it) }
                        }
                        val current = blocks[index]
                        if (delta != null && current != null) {
                            val updated = current.toMutableMap()
                            listOf("text", "thinking", "signature").forEach { field ->
                                val piece = (delta[field] as? JsonPrimitive)?.contentOrNull ?: return@forEach
                                updated[field] = JsonPrimitive(((updated[field] as? JsonPrimitive)?.contentOrNull ?: "") + piece)
                            }
                            blocks[index] = JsonObject(updated)
                        } else replayStateValid = false
                    }
                    "message_delta" -> outputTokens = (((root?.get("usage") as? JsonObject)?.get("output_tokens") as? JsonPrimitive)?.contentOrNull?.toIntOrNull()) ?: outputTokens
                }
                events
            }, onDone = {
                StreamEvent.Done(ProviderChatResult(text.trim(), inputTokens, outputTokens, reasoningText = reasoning.trim().ifEmpty { null }))
            }).collect { event ->
                if (event is StreamEvent.Done && replayStateValid && blocks.isNotEmpty()) {
                    val finalized = blocks.map { (index, block) ->
                        val rawInput = partialInputs[index]?.toString()?.takeIf(String::isNotBlank)
                        val input = rawInput?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
                        if (rawInput != null && input == null) replayStateValid = false
                        if (input == null) block else JsonObject(block + ("input" to input))
                    }
                    if (replayStateValid && finalized.all { it.isValidMiniMaxAnthropicBlock(partial = false) }) {
                        emit(StreamEvent.RecipeContinuation("replay_blocks", route.selection.continuationVariant, JsonObject(mapOf("blocks" to JsonArray(finalized)))))
                    }
                }
                emit(event)
            }
        }
    }

    private suspend fun sendAnthropicWebMessage(
        route: AnthropicWebRoute,
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done {
        val body = buildAnthropicWebBody(route, modelID, messages, stream = false, requestOptions)
            ?: throw ProviderServiceError.InvalidConfiguration("Invalid MiniMax web-search recipe.")
        val response = client.post(miniMaxAlternateRouteURL(baseUrl, route.path)) {
            route.headers.forEach { (name, value) -> header(name, value) }
            header(route.authHeader, apiKey)
            setBody(body.toString())
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val raw = response.bodyAsText()
        val root = json.parseToJsonElement(raw).jsonObject
        val content = root["content"] as? JsonArray ?: JsonArray(emptyList())
        val text = content.mapNotNull { ((it as? JsonObject)?.get("text") as? JsonPrimitive)?.contentOrNull }.joinToString("").trim()
        val reasoning = content.mapNotNull { ((it as? JsonObject)?.get("thinking") as? JsonPrimitive)?.contentOrNull }.joinToString("").trim()
        val citations = ai.oriveo.community.core.provider.transport.AnthropicMessagesStrategy(json).parseCitations(
            raw, ai.oriveo.community.core.provider.transport.StreamShape(citationSnippetField = "content"),
        )
        val usage = root["usage"] as? JsonObject
        val promptTokens = (usage?.get("input_tokens") as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
        val completionTokens = (usage?.get("output_tokens") as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
        val breakdown = UsageBreakdown(promptTokens = promptTokens, completionTokens = completionTokens)
        val (cost, source) = CostCalculator.calcCost(breakdown, MetadataClient.resolveCatalogModel(modelID, ProviderKind.MiniMax))
        return StreamEvent.Done(ProviderChatResult(
            text = text,
            promptTokens = promptTokens,
            completionTokens = completionTokens,
            estimatedCost = cost,
            reasoningText = reasoning.ifEmpty { null }, citations = citations.ifEmpty { null }, costSource = source.name,
        ))
    }

    private fun miniMaxAlternateRouteURL(baseUrl: String?, path: String): String {
        val base = URI(resolveBaseUrl(baseUrl))
        return URI(base.scheme, base.userInfo, base.host, base.port, path, null, null).toString()
    }

    private fun JsonElement?.asArrayItems(): List<JsonElement> = (this as? JsonArray)?.toList().orEmpty()

    private fun JsonObject.isValidMiniMaxAnthropicBlock(partial: Boolean): Boolean {
        val type = (this["type"] as? JsonPrimitive)?.contentOrNull ?: return false
        return when (type) {
            "thinking" -> (this["thinking"] as? JsonPrimitive) != null &&
                (partial || (this["signature"] as? JsonPrimitive)?.contentOrNull?.isNotEmpty() == true)
            "redacted_thinking" -> (this["data"] as? JsonPrimitive)?.contentOrNull?.isNotEmpty() == true
            "text" -> (this["text"] as? JsonPrimitive) != null
            "server_tool_use" -> (this["id"] as? JsonPrimitive)?.contentOrNull?.isNotEmpty() == true &&
                (this["name"] as? JsonPrimitive)?.contentOrNull == "web_search" &&
                (partial || this["input"] is JsonObject)
            "web_search_tool_result" -> (this["tool_use_id"] as? JsonPrimitive)?.contentOrNull?.isNotEmpty() == true &&
                (this["content"] as? JsonArray)?.all { result ->
                    val item = result as? JsonObject ?: return@all false
                    (item["type"] as? JsonPrimitive)?.contentOrNull == "web_search_result" &&
                        (item["url"] as? JsonPrimitive)?.contentOrNull?.isNotEmpty() == true &&
                        item["title"] is JsonPrimitive && item["content"] is JsonPrimitive
                } == true
            else -> false
        }
    }

    private fun JsonObject.insertMiniMaxReplayBeforeNewestUser(replay: JsonArray): JsonObject {
        val messages = (this["messages"] as? JsonArray)?.toMutableList() ?: return this
        val index = messages.indexOfLast { ((it as? JsonObject)?.get("role") as? JsonPrimitive)?.contentOrNull == "user" }
            .let { if (it < 0) messages.size else it }
        messages.addAll(index, replay)
        return JsonObject(toMutableMap().apply { put("messages", JsonArray(messages)) })
    }

}
