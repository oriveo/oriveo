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
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import java.net.URI
import java.time.Instant
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

/**
 * Moonshot / Kimi Service - OpenAI-compatible, api.moonshot.ai.
 *
 * Citations are parsed by the base class [OpenAICompatibleService] through
 * [ai.oriveo.community.core.provider.transport.TransportRegistry]: the openai_chat strategy
 * plus the kimi_web_search profile (the builtin `${'$'}web_search` tool).
 * With web search on, sendMessageStream runs a streaming tool loop - each leg streams and
 * emits in real time, and accumulated tool_calls are fed back to start the next leg. With it
 * off, the request goes straight to the parent's standard streaming parser.
 */
class MoonshotService(
    client: HttpClient,
    json: Json,
    transportRegistry: ai.oriveo.community.core.provider.transport.TransportRegistry,
) : OpenAICompatibleService(
    client = client,
    json = json,
    defaultBaseUrl = "https://api.moonshot.ai/v1",
    providerName = "Kimi",
    providerKind = ProviderKind.Moonshot,
    transportRegistry = transportRegistry,
), ai.oriveo.community.core.provider.BalanceQueryable {

    companion object {
        private const val DEFAULT_ORIGIN = "https://api.moonshot.ai"
    }

    /**
     * Balance: `GET ${origin}/v1/users/me/balance` ->
     * `data.{available_balance, voucher_balance, cash_balance}`.
     * cash_balance can go negative when the account is in arrears, which the UI has to warn
     * about.
     *
     * Two hosts share one path: `api.moonshot.ai` (international, USD) and
     * `api.moonshot.cn` (domestic, CNY), so the currency is derived from the host rather
     * than hard-coded.
     */
    override suspend fun fetchBalance(apiKey: String, baseURL: String?): ai.oriveo.community.core.provider.ProviderBalance {
        if (apiKey.isBlank()) throw ProviderServiceError.InvalidAPIKey("API key is empty.")
        val origin = ai.oriveo.community.core.provider.balanceOriginOf(baseURL, DEFAULT_ORIGIN)
        val response = client.get("$origin/v1/users/me/balance") {
            applyHeaders(apiKey)
        }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val envelope = json.decodeFromString<BalanceEnvelope>(response.bodyAsText())
        val data = envelope.data ?: throw ProviderServiceError.Upstream(200, "Moonshot balance payload missing data.")
        // Currency follows the host: moonshot.cn -> CNY; moonshot.ai and any custom host -> USD
        val host = runCatching { java.net.URI.create(origin).host?.lowercase() }.getOrNull().orEmpty()
        val currency = if (host.endsWith("moonshot.cn")) "CNY" else "USD"
        return ai.oriveo.community.core.provider.ProviderBalance(
            currency = currency,
            total = data.available_balance ?: 0.0,
            granted = data.voucher_balance,
            topUp = data.cash_balance,
            fetchedAt = Instant.now(),
        )
    }

    @Serializable
    private data class BalanceEnvelope(
        val code: Int? = null,
        val data: BalancePayload? = null,
    )

    @Serializable
    private data class BalancePayload(
        val available_balance: Double? = null,
        val voucher_balance: Double? = null,
        val cash_balance: Double? = null,
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

    /**
     * Moonshot puts cached_tokens at the TOP level of `usage`, not as a sub-field of
     * prompt_tokens_details. Reading it from the usual place gets it wrong.
     */
    override fun parseUsage(usage: JsonObject?): ai.oriveo.community.core.provider.UsageBreakdown {
        if (usage == null) return ai.oriveo.community.core.provider.UsageBreakdown()
        val prompt = usage["prompt_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val completion = usage["completion_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        val cached = usage["cached_tokens"]?.jsonPrimitive?.intOrNull ?: 0
        return ai.oriveo.community.core.provider.UsageBreakdown(
            promptTokens = (prompt - cached).coerceAtLeast(0),
            cachedInputTokens = cached,
            completionTokens = completion,
            reasoningTokens = 0,  // kimi-k2-thinking has no separate field either; it is already inside completion
            cacheReadObserved = usage["cached_tokens"]?.jsonPrimitive?.intOrNull != null,
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
    ): Flow<StreamEvent> {
        if (!webSearchEnabled) {
            return super.sendMessageStream(
                apiKey = apiKey,
                modelID = modelID,
                messages = messages,
                baseUrl = baseUrl,
                supportsImageGen = supportsImageGen,
                reasoningMode = reasoningMode,
                webSearchEnabled = false,
                requestOptions = requestOptions,
            )
        }

        return flow {
            if (apiKey.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing API key.")
            if (modelID.isBlank()) throw ProviderServiceError.InvalidConfiguration("Missing model identifier.")
            MetadataClient.ensureInitialized()
            // The local multi-leg path is entered only when an exact capability control
            // activates client_tool_loop. A miss against a valid runtime has to degrade to a
            // plain chat, so that an older Kimi profile cannot quietly restart the search.
            val runtime = MetadataClient.capabilityRuntimeRequest(
                providerKind = ProviderKind.Moonshot,
                modelID = modelID,
                finalTransport = TransportKind.OpenAIChat.wireValue,
                webRequested = true,
                reasoningMode = reasoningMode,
            )
            if (runtime != null && runtime.selections.none { it.capability == "web" && it.executionKind == "client_tool_loop" }) {
                emitAll(
                    super.sendMessageStream(
                        apiKey, modelID, messages, baseUrl, supportsImageGen, reasoningMode,
                        webSearchEnabled = false, requestOptions = requestOptions,
                    ),
                )
                return@flow
            }

            val url = resolveBaseUrl(baseUrl)
            val webRecipe = runtime?.selections?.firstOrNull {
                it.capability == "web" && it.executionKind == "client_tool_loop"
            }
            val toolLoopVariant = webRecipe?.continuationVariant ?: "default"
            val formula = webRecipe?.formula
            val initialBody = applyCapabilityRuntimeCustomFragment(buildChatRequest(
                modelID = modelID,
                messages = messages,
                stream = true,
                reasoningMode = reasoningMode,
                webSearchEnabled = true,
                supportsImageGen = supportsImageGen,
                requestOptions = requestOptions,
            ), ProviderKind.Moonshot, modelID, TransportKind.OpenAIChat.wireValue, requestOptions)

            // Streaming tool loop: every leg is a streaming request, so reasoning and delta
            // are emitted live. If a leg ends having accumulated tool_calls ($web_search is
            // executed by Kimi's own service and the client only feeds the arguments back),
            // another leg follows; otherwise this wraps up.
            var bodyTemplate = json.parseToJsonElement(initialBody).jsonObject
            if (formula != null) {
                val tools = fetchFormulaTools(url, formula, apiKey)
                val existing = (bodyTemplate["tools"] as? JsonArray).orEmpty()
                bodyTemplate = JsonObject(bodyTemplate.toMutableMap().apply { put("tools", JsonArray(mergeFormulaTools(existing, tools))) })
            }
            val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Moonshot)
            val maxToolLoops = runtime?.selections
                ?.firstOrNull { it.capability == "web" && it.executionKind == "client_tool_loop" }
                ?.maxToolLoops
                ?.coerceIn(1, 5)
                ?: webSearchMaxToolLoops(resolved?.profiles?.webSearch)?.coerceIn(1, 5)
                ?: 4
            val requestMessages = bodyTemplate["messages"]?.jsonArray?.toMutableList() ?: mutableListOf()
            val completedMessages = mutableListOf<JsonElement>()
            // A sidecar can only be supplied by ChatRepository's explicit continue/retry path.
            // It is protocol-gated again here so another provider's opaque state can never leak
            // into an OpenAI-chat request.
            requestOptions.localContinuationState?.let { state ->
                val mapped = ProviderRecipeExecution.continuation(
                    kind = "tool_loop",
                    variant = toolLoopVariant,
                    protocol = TransportKind.OpenAIChat.wireValue,
                    intent = ai.oriveo.community.core.model.RequestPreferenceResolver.ContinuationIntent(
                        kind = "tool_loop",
                        variant = toolLoopVariant,
                        step = 1,
                        state = state,
                    ),
                )
                if (mapped is ProviderRecipeExecution.ContinuationWire.Messages && webRecipe != null) {
                    val newUserIndex = requestMessages.indexOfLast {
                        ((it as? JsonObject)?.get("role") as? JsonPrimitive)?.contentOrNull == "user"
                    }.takeIf { it >= 0 } ?: requestMessages.size
                    requestMessages.addAll(newUserIndex, mapped.append)
                    completedMessages.addAll(mapped.append)
                }
                // Missing/corrupt/recipe-mismatch state intentionally falls through to plain chat.
            }
            val accumulatedText = StringBuilder()
            val accumulatedReasoning = StringBuilder()
            var totalPrompt = 0
            var totalCompletion = 0
            var totalCached = 0
            var hasUsage = false
            var pendingToolCalls = false

            // One first leg plus the tool loop ceiling the profile specifies; when an older
            // catalog snapshot lacks the field, default to 4.
            for (leg in 0..maxToolLoops) {
                val body = JsonObject(
                    bodyTemplate.toMutableMap().apply { put("messages", JsonArray(requestMessages)) },
                )
                val legText = StringBuilder()
                val legReasoning = StringBuilder()
                var legUsage: JsonObject? = null
                val toolAccumulator = MoonshotToolCallAccumulator()

                UnsupportedParamRetry.run(
                    ProviderKind.Moonshot,
                    modelID,
                    body.toString(),
                    requestOptions = requestOptions,
                    identity = officialSelfHealIdentity(
                        providerKind = ProviderKind.Moonshot,
                        modelID = modelID,
                        options = requestOptions,
                        finalTransport = TransportKind.OpenAIChat.wireValue,
                        finalUrl = "$url/chat/completions",
                    ),
                ) { requestBodyAttempt ->
                    val statement = client.preparePost("$url/chat/completions") {
                        applyHeaders(apiKey)
                        contentType(ContentType.Application.Json)
                        setBody(requestBodyAttempt)
                    }
                    requestOptions.capabilityExecutionCollector?.confirmDispatched()
                    statement.execute { response ->
                        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
                        SseParser.parseOpenAICompatibleMulti(
                            response = response,
                            json = json,
                            onChunk = { payload ->
                                val events = mutableListOf<StreamEvent>()
                                val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
                                if (root != null) {
                                    (root["usage"] as? JsonObject)?.let { legUsage = it }
                                    val delta = ((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)
                                        ?.get("delta") as? JsonObject
                                    (delta?.get("tool_calls") as? JsonArray)?.let { toolAccumulator.ingest(it) }
                                    val reasoning = (delta?.get("reasoning_content") as? JsonPrimitive)?.contentOrNull
                                    if (!reasoning.isNullOrEmpty()) {
                                        // Insert a paragraph break across legs so the
                                        // streaming accumulation matches the finalized text
                                        // character for character.
                                        if (legReasoning.isEmpty() && accumulatedReasoning.isNotEmpty()) {
                                            accumulatedReasoning.append("\n\n")
                                            events += StreamEvent.Reasoning("\n\n")
                                        }
                                        legReasoning.append(reasoning)
                                        accumulatedReasoning.append(reasoning)
                                        events += StreamEvent.Reasoning(reasoning)
                                    }
                                    val content = (delta?.get("content") as? JsonPrimitive)?.contentOrNull
                                    if (!content.isNullOrEmpty()) {
                                        legText.append(content)
                                        accumulatedText.append(content)
                                        events += StreamEvent.Delta(content)
                                    }
                                }
                                events
                            },
                            // Placeholder Done at the end of a leg: the outer layer does the
                            // real finish, so this is filtered out during collect.
                            onDone = { StreamEvent.Done(ProviderChatResult(text = "")) },
                        ).collect { event ->
                            if (event !is StreamEvent.Done) emit(event)
                        }
                    }
                }

                legUsage?.let { usage ->
                    hasUsage = true
                    totalPrompt += usage["prompt_tokens"]?.jsonPrimitive?.intOrNull ?: 0
                    totalCompletion += usage["completion_tokens"]?.jsonPrimitive?.intOrNull ?: 0
                    totalCached += usage["cached_tokens"]?.jsonPrimitive?.intOrNull ?: 0
                }

                val toolCalls = toolAccumulator.finalized()
                pendingToolCalls = toolCalls.isNotEmpty()
                if (!pendingToolCalls) break
                // `0..maxToolLoops` allows the configured number of completed tool rounds
                // plus one final answer request. A further tool call is never a partial
                // success: persisting/returning it would leave an orphan continuation.
                if (leg >= maxToolLoops) {
                    throw ProviderServiceError.InvalidConfiguration("Moonshot tool-loop limit exceeded.")
                }

                // Feed back: echo the assistant tool-call message plus the tool result, with
                // arguments returned verbatim.
                // Kimi's contract: when thinking is in effect (enabled by default on k2.5 and
                // k2.6), an assistant tool-call message without reasoning_content is rejected
                // with a 400. An empty string passes, which matters because the model may go
                // straight to searching without thinking at all.
                val assistantToolMessage = buildJsonObject {
                        put("role", JsonPrimitive("assistant"))
                        put("content", JsonPrimitive(legText.toString()))
                        put("reasoning_content", JsonPrimitive(legReasoning.toString()))
                        put("tool_calls", JsonArray(toolCalls.map { it.asJsonObject() }))
                    }
                requestMessages.add(assistantToolMessage)
                completedMessages += assistantToolMessage
                for (toolCall in toolCalls) {
                    val toolResult = if (formula == null) toolCall.asToolResultMessage() else formulaToolResult(url, formula, apiKey, toolCall)
                    requestMessages.add(toolResult)
                    completedMessages += toolResult
                }
                if (webRecipe != null && completedMessages.isNotEmpty()) {
                    val state = JsonObject(mapOf("completedMessages" to JsonArray(completedMessages.toList())))
                    val valid = ProviderRecipeExecution.continuation(
                        kind = "tool_loop",
                        variant = webRecipe.continuationVariant,
                        protocol = TransportKind.OpenAIChat.wireValue,
                        intent = ai.oriveo.community.core.model.RequestPreferenceResolver.ContinuationIntent(
                        kind = "tool_loop", variant = toolLoopVariant, step = 1, state = state,
                        ),
                    ) is ProviderRecipeExecution.ContinuationWire.Messages
                    if (!valid) throw ProviderServiceError.InvalidConfiguration("Invalid Moonshot tool-loop continuation state.")
                    emit(StreamEvent.RecipeContinuation("tool_loop", toolLoopVariant, state))
                }
            }

            val text = accumulatedText.toString().trim()
            // Defensive invariant: the guard in the loop must already have rejected this.
            // Keep it here so a future loop refactor cannot emit Done after dangling calls.
            if (pendingToolCalls) throw ProviderServiceError.InvalidConfiguration("Moonshot tool-loop ended with pending calls.")

            // Each leg is billed separately, so usage is summed across legs and then goes
            // through the same parseUsage channel (cached_tokens is at the top level).
            val usageJson = if (hasUsage) {
                buildJsonObject {
                    put("prompt_tokens", JsonPrimitive(totalPrompt))
                    put("completion_tokens", JsonPrimitive(totalCompletion))
                    put("cached_tokens", JsonPrimitive(totalCached))
                }
            } else {
                null
            }
            val breakdown = parseUsage(usageJson)
            val (cost, source) = ai.oriveo.community.core.provider.CostCalculator.calcCost(breakdown, resolved)
            emit(
                StreamEvent.Done(
                    ProviderChatResult(
                        text = text,
                        promptTokens = breakdown.promptTokens + breakdown.cachedInputTokens,
                        completionTokens = breakdown.completionTokens,
                        estimatedCost = cost,
                        reasoningText = accumulatedReasoning.toString().trim().takeIf { it.isNotEmpty() },
                        cachedInputTokens = breakdown.reportedCachedInputTokens,
                        costSource = source.name,
                    ),
                ),
            )
        }
    }

    private suspend fun fetchFormulaTools(baseUrl: String, formula: JsonObject, apiKey: String): List<JsonElement> {
        val path = formula.string("toolsPath") ?: throw ProviderServiceError.InvalidConfiguration("Formula tools route missing.")
        val response = client.get(formulaUrl(baseUrl, path)) { applyHeaders(apiKey) }
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val root = runCatching { json.parseToJsonElement(response.bodyAsText()).jsonObject }.getOrNull()
            ?: throw ProviderServiceError.Upstream(200, "Formula tools payload invalid.")
        val tools = (root["tools"] as? JsonArray)?.toList() ?: throw ProviderServiceError.Upstream(200, "Formula tools missing.")
        return mergeFormulaTools(emptyList(), tools)
    }

    private suspend fun formulaToolResult(baseUrl: String, formula: JsonObject, apiKey: String, call: MoonshotToolCall): JsonObject {
        val function = call.function ?: throw ProviderServiceError.Upstream(200, "Formula call has no function.")
        val callId = call.id?.takeIf { it.isNotBlank() }
            ?: throw ProviderServiceError.Upstream(200, "Formula call is missing an id.")
        val functionName = function.name?.takeIf { it.isNotBlank() }
        val rawArguments = function.arguments
        if (functionName == null || rawArguments == null) {
            throw ProviderServiceError.Upstream(200, "Formula call is malformed.")
        }
        val path = formula.string("fibersPath") ?: throw ProviderServiceError.InvalidConfiguration("Formula fibers route missing.")
        val response = client.preparePost(formulaUrl(baseUrl, path)) {
            applyHeaders(apiKey); contentType(ContentType.Application.Json)
            // arguments is intentionally a JSON string; no parse/re-serialization of opaque Kimi payload.
            setBody(buildJsonObject {
                put("name", JsonPrimitive(functionName))
                put("arguments", JsonPrimitive(rawArguments))
            }.toString())
        }.execute()
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val context = runCatching { json.parseToJsonElement(response.bodyAsText()).jsonObject["context"] as? JsonObject }.getOrNull()
        val output = context?.string("output") ?: context?.string("encrypted_output")
            ?: throw ProviderServiceError.Upstream(200, "Formula Fiber result missing output.")
        return buildJsonObject {
            put("role", JsonPrimitive("tool")); put("tool_call_id", JsonPrimitive(callId)); put("name", JsonPrimitive(functionName)); put("content", JsonPrimitive(output))
        }
    }

    private fun formulaUrl(baseUrl: String, path: String): String {
        val base = URI(baseUrl)
        val lowerPath = path.lowercase()
        val lowerBasePath = base.rawPath.orEmpty().lowercase()
        if (base.scheme !in setOf("http", "https") || base.authority.isNullOrBlank() ||
            base.userInfo != null || base.query != null || base.fragment != null ||
            base.path.orEmpty().split('/').any { it == ".." } || "%2e" in lowerBasePath ||
            !path.startsWith("/v1/formulas/") || path.contains("..") || "%2e" in lowerPath ||
            path.contains('?') || path.contains('#')
        ) {
            throw ProviderServiceError.InvalidConfiguration("Formula route rejected.")
        }
        val chatRoot = base.path.orEmpty().trimEnd('/').removeSuffix("/chat/completions").trimEnd('/')
        val versionedRoot = if (chatRoot.endsWith("/v1")) chatRoot else "$chatRoot/v1"
        val joined = versionedRoot + path.removePrefix("/v1")
        if (!joined.startsWith("$versionedRoot/formulas/")) {
            throw ProviderServiceError.InvalidConfiguration("Formula route escaped API root.")
        }
        return URI(base.scheme, base.authority, joined, null, null).toString()
    }

    private fun mergeFormulaTools(base: List<JsonElement>, extra: List<JsonElement>): List<JsonElement> {
        val names = linkedSetOf<String>()
        fun addAll(items: List<JsonElement>) = items.forEach { item ->
            val name = ((item as? JsonObject)?.get("function") as? JsonObject)?.string("name")
                ?: throw ProviderServiceError.InvalidConfiguration("Formula tool declaration invalid.")
            if (!names.add(name)) throw ProviderServiceError.InvalidConfiguration("Formula tool name duplicated.")
        }
        addAll(base); addAll(extra)
        return base + extra
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    /**
     * Merges streaming tool_calls deltas by index: id/type/name take the first non-empty
     * value, arguments are concatenated piece by piece.
     */
    private class MoonshotToolCallAccumulator {
        private class Builder {
            var id: String? = null
            var type: String? = null
            var name: String? = null
            val arguments = StringBuilder()
        }

        private val builders = sortedMapOf<Int, Builder>()

        fun ingest(deltas: JsonArray) {
            for (element in deltas) {
                val obj = element as? JsonObject ?: continue
                val index = (obj["index"] as? JsonPrimitive)?.intOrNull ?: 0
                val builder = builders.getOrPut(index) { Builder() }
                (obj["id"] as? JsonPrimitive)?.contentOrNull?.let { builder.id = it }
                (obj["type"] as? JsonPrimitive)?.contentOrNull?.let { builder.type = it }
                val function = obj["function"] as? JsonObject
                (function?.get("name") as? JsonPrimitive)?.contentOrNull?.let { builder.name = it }
                (function?.get("arguments") as? JsonPrimitive)?.contentOrNull?.let { builder.arguments.append(it) }
            }
        }

        fun finalized(): List<MoonshotToolCall> = builders.map { (_, builder) ->
            MoonshotToolCall(
                id = builder.id,
                type = builder.type,
                function = MoonshotToolFunction(name = builder.name, arguments = builder.arguments.toString()),
            )
        }
    }

    @Serializable
    private data class MoonshotToolCall(
        val id: String? = null,
        val type: String? = null,
        val function: MoonshotToolFunction? = null,
    ) {
        fun asJsonObject(): JsonObject {
            val fields = mutableMapOf<String, JsonElement>()
            id?.let { fields["id"] = JsonPrimitive(it) }
            type?.let { fields["type"] = JsonPrimitive(it) }
            function?.let { fields["function"] = it.asJsonObject() }
            return JsonObject(fields)
        }

        fun asToolResultMessage(): JsonObject {
            return JsonObject(
                mapOf(
                    "role" to JsonPrimitive("tool"),
                    "tool_call_id" to JsonPrimitive(id ?: ""),
                    "name" to JsonPrimitive(function?.name ?: "${'$'}web_search"),
                    "content" to JsonPrimitive(toolResultContent()),
                ),
            )
        }

        private fun toolResultContent(): String {
            if (function?.name != "${'$'}web_search") return """{"error":"Unsupported tool"}"""
            return function.arguments ?: "{}"
        }
    }

    @Serializable
    private data class MoonshotToolFunction(
        val name: String? = null,
        val arguments: String? = null,
    ) {
        fun asJsonObject(): JsonObject {
            val fields = mutableMapOf<String, JsonElement>()
            name?.let { fields["name"] = JsonPrimitive(it) }
            arguments?.let { fields["arguments"] = JsonPrimitive(it) }
            return JsonObject(fields)
        }
    }

}
