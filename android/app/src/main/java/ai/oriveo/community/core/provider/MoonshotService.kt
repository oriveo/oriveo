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
import ai.oriveo.community.core.model.ToolCallDelta
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.tools.OpenAIChatToolAdapter
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolRegistry
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
import kotlinx.serialization.json.put

/**
 * Moonshot / Kimi Service - OpenAI-compatible, api.moonshot.ai.
 *
 * Citations are parsed by the base class [OpenAICompatibleService] through
 * [ai.oriveo.community.core.provider.transport.TransportRegistry]: the openai_chat strategy
 * plus the kimi_web_search profile (the builtin `${'$'}web_search` tool).
 * With web search on, sendMessageStream runs the generic `ToolCallLoop` (the leg runner and the
 * registry entries live in `MoonshotToolLoop.kt`). With it off, the request goes straight to the
 * parent's standard streaming parser.
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
            var bodyTemplate = json.parseToJsonElement(applyCapabilityRuntimeCustomFragment(buildChatRequest(
                modelID = modelID,
                messages = messages,
                stream = true,
                reasoningMode = reasoningMode,
                webSearchEnabled = true,
                supportsImageGen = supportsImageGen,
                requestOptions = requestOptions,
            ), ProviderKind.Moonshot, modelID, TransportKind.OpenAIChat.wireValue, requestOptions)).jsonObject

            // A Formula extends web search dynamically: the function names and wire types that
            // /tools declares go into the request body and into the registry allowlist.
            var formulaRegistrations: List<MoonshotFormulaToolRegistration> = emptyList()
            if (formula != null) {
                val tools = fetchFormulaTools(url, formula, apiKey)
                val existing = (bodyTemplate["tools"] as? JsonArray).orEmpty()
                bodyTemplate = JsonObject(bodyTemplate.toMutableMap().apply {
                    put("tools", JsonArray(mergeFormulaTools(existing, tools)))
                })
                formulaRegistrations = moonshotFormulaRegistrations(tools)
            }

            val resolved = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Moonshot)
            // Effective ceiling = min(value from the catalog, 8), 6 when absent.
            val serverLoops = webRecipe?.maxToolLoops
                ?: webSearchMaxToolLoops(resolved?.profiles?.webSearch)
            val maxSteps = ToolCallLoop.Limits.effectiveMaxSteps(serverLoops)

            val baseMessages = bodyTemplate["messages"]?.jsonArray?.toMutableList() ?: mutableListOf()
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
                    val newUserIndex = baseMessages.indexOfLast {
                        ((it as? JsonObject)?.get("role") as? JsonPrimitive)?.contentOrNull == "user"
                    }.takeIf { it >= 0 } ?: baseMessages.size
                    baseMessages.addAll(newUserIndex, mapped.append)
                    completedMessages.addAll(mapped.append)
                }
                // Missing/corrupt/recipe-mismatch state intentionally falls through to plain chat.
            }

            // A tool only has an executor while web search is on: the builtin one is always
            // `$web_search`, and a Formula registers whatever `/tools` declares.
            val registry = if (formula != null) {
                ToolRegistry(formulaRegistrations.map { registration ->
                    MoonshotWebSearchTool(
                        name = registration.name,
                        wireType = registration.wireType,
                    ) { call -> formulaFiberContent(url, formula, apiKey, call) }
                })
            } else {
                ToolRegistry(listOf(MoonshotWebSearchTool { call ->
                    MoonshotWebSearchTool.builtinResultContent(call)
                }))
            }

            val legRunner = MoonshotToolLoopLegRunner(
                client = client,
                json = json,
                providerKind = ProviderKind.Moonshot,
                modelID = modelID,
                endpoint = "$url/chat/completions",
                baseBody = bodyTemplate,
                baseMessages = baseMessages,
                requestOptions = requestOptions,
                identity = officialSelfHealIdentity(
                    providerKind = ProviderKind.Moonshot,
                    modelID = modelID,
                    options = requestOptions,
                    finalTransport = TransportKind.OpenAIChat.wireValue,
                    finalUrl = "$url/chat/completions",
                ),
                applyAuth = { applyHeaders(apiKey) },
            )

            var unhandledToolCallIndex = 0
            val loop = ToolCallLoop(
                registry = registry,
                legRunner = legRunner,
                adapter = OpenAIChatToolAdapter(includesToolNameInResult = true),
                limits = ToolCallLoop.Limits(maxSteps = maxSteps),
                // Kimi's contract: when thinking is in effect (enabled by default on k2.5 and
                // k2.6), an assistant tool-call message without reasoning_content is rejected
                // with a 400. An empty string passes, which matters because the model may go
                // straight to searching without thinking at all.
                includesReasoningInAssistantMessage = true,
                // Web search has no `[n]` citation scheme: the sentences appended for Kimi when
                // the ceiling is hit use web search's own wording.
                prompts = MOONSHOT_WEB_SEARCH_PROMPTS,
                onUnhandledToolCalls = { calls ->
                    // This callback can fire several times in one run (once per leg that carries
                    // an unregistered tool, plus the final leg). Downstream,
                    // `NativeToolCallAccumulator.merge` joins the fragments of one call by index:
                    // numbering from 0 every time would make the second leg's call look like a
                    // later fragment of the first leg's, concatenating their arguments. So the
                    // index increases monotonically across the whole run.
                    emit(StreamEvent.ToolCallDeltas(calls.map { call ->
                        ToolCallDelta(
                            index = unhandledToolCallIndex++,
                            id = call.id,
                            type = call.type,
                            name = call.function.name,
                            arguments = call.function.arguments,
                        )
                    }))
                },
                onLegCompleted = { record ->
                    if (webRecipe != null) {
                        completedMessages += moonshotMessageJson(record.assistantMessage)
                        record.toolResultMessages.forEach { message ->
                            completedMessages += moonshotMessageJson(message)
                        }
                        val state = buildJsonObject {
                            put("completedMessages", JsonArray(completedMessages.toList()))
                        }
                        val valid = ProviderRecipeExecution.continuation(
                            kind = "tool_loop",
                            variant = toolLoopVariant,
                            protocol = TransportKind.OpenAIChat.wireValue,
                            intent = ai.oriveo.community.core.model.RequestPreferenceResolver.ContinuationIntent(
                                kind = "tool_loop", variant = toolLoopVariant, step = 1, state = state,
                            ),
                        ) is ProviderRecipeExecution.ContinuationWire.Messages
                        if (!valid) throw ProviderServiceError.InvalidConfiguration("Invalid Moonshot tool-loop continuation state.")
                        emit(StreamEvent.RecipeContinuation("tool_loop", toolLoopVariant, state))
                    }
                },
            )

            val accumulatedText = StringBuilder()
            val accumulatedReasoning = StringBuilder()
            var legSawReasoning = false
            loop.run(initialMessages = emptyList()) { event ->
                when (event) {
                    is ToolCallLoop.ProgressEvent.LegStarted -> legSawReasoning = false
                    is ToolCallLoop.ProgressEvent.TextDelta -> {
                        accumulatedText.append(event.text)
                        emit(StreamEvent.Delta(event.text))
                    }
                    is ToolCallLoop.ProgressEvent.ReasoningDelta -> {
                        // Insert a paragraph break across legs so the streaming accumulation
                        // matches the finalized text character for character.
                        if (!legSawReasoning && accumulatedReasoning.isNotEmpty()) {
                            accumulatedReasoning.append("\n\n")
                            emit(StreamEvent.Reasoning("\n\n"))
                        }
                        legSawReasoning = true
                        accumulatedReasoning.append(event.text)
                        emit(StreamEvent.Reasoning(event.text))
                    }
                    is ToolCallLoop.ProgressEvent.Usage -> Unit
                    is ToolCallLoop.ProgressEvent.ToolCallsAccepted -> {
                        // Emitted before the feed-back: the search really happens inside the next
                        // leg's request, and the screen needs a label during that wait.
                        MoonshotWebSearchTool.streamActivity(event.toolCalls)?.let {
                            emit(StreamEvent.Activity(it))
                        }
                    }
                }
            }

            val text = accumulatedText.toString().trim()
            // Each leg is billed separately, so usage is summed across legs and then goes
            // through the same parseUsage channel (cached_tokens is at the top level).
            val usages = legRunner.collectedUsages
            val usageJson = if (usages.isNotEmpty()) {
                buildJsonObject {
                    put("prompt_tokens", JsonPrimitive(usages.sumOf { it.promptTokens }))
                    put("completion_tokens", JsonPrimitive(usages.sumOf { it.completionTokens }))
                    put("cached_tokens", JsonPrimitive(usages.sumOf { it.cachedTokens }))
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

    /** Formula Fiber: hands one call of a dynamic tool to `/fibers` and returns the raw output to feed back to the model. */
    private suspend fun formulaFiberContent(
        baseUrl: String,
        formula: JsonObject,
        apiKey: String,
        call: ToolLoopToolCall,
    ): String {
        if (call.function.name.isBlank()) throw ProviderServiceError.Upstream(200, "Formula call is malformed.")
        val path = formula.string("fibersPath") ?: throw ProviderServiceError.InvalidConfiguration("Formula fibers route missing.")
        val response = client.preparePost(formulaUrl(baseUrl, path)) {
            applyHeaders(apiKey); contentType(ContentType.Application.Json)
            // arguments is intentionally a JSON string; no parse/re-serialization of opaque Kimi payload.
            setBody(moonshotFormulaFiberBody(call))
        }.execute()
        if (!response.status.isSuccess()) throw SseParser.mapHttpError(response)
        val context = runCatching { json.parseToJsonElement(response.bodyAsText()).jsonObject["context"] as? JsonObject }.getOrNull()
        return context?.string("output") ?: context?.string("encrypted_output")
            ?: throw ProviderServiceError.Upstream(200, "Formula Fiber result missing output.")
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

}
