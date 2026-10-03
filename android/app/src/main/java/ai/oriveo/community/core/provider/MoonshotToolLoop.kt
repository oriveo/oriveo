package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolExecutionOutcome
import ai.oriveo.community.core.tools.ToolLoopLegEvent
import ai.oriveo.community.core.tools.ToolLoopLegRequest
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolCallDelta
import ai.oriveo.community.core.tools.ToolLoopToolChoice
import ai.oriveo.community.core.tools.ToolLoopUsage
import ai.oriveo.community.core.tools.ToolRegistryEntry
import ai.oriveo.community.core.tools.ToolScope
import io.ktor.client.HttpClient
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

// The three pieces Moonshot web search plugs into the generic loop: registry entry / leg executor / progress translation.
//
// Only web search's own policy lives here: the builtin `$web_search` arguments are echoed back verbatim,
// Formula tools are registered dynamically and executed through Fiber, and usage is collected per leg because
// each leg is billed separately. The loop itself, message shapes, tool_calls assembly and the allowlist all come from `core/tools/`.
//

/**
 * What Kimi is told when the step cap or the budget is hit. The generic loop's defaults are neutrally worded; these use
 * web search's own phrasing. No citation numbers: web-search citations come from Kimi's own annotations, the text has no `[n]`.
 */
internal val MOONSHOT_WEB_SEARCH_PROMPTS = ToolCallLoop.Prompts(
    stepLimitReached = "The web search limit was reached. Answer now using the search results you already have. Do not call another tool.",
    tokenBudgetReached = "The token budget for web search was reached. Answer now using the search results you already have and do not call another tool. If they are not enough to answer, say so clearly.",
    stoppedByStepLimit = "The web search limit was reached.",
    stoppedByTokenBudget = "The token budget for web search was reached.",
)

/**
 * Registry entry for Kimi web search: the builtin path is the fixed `$web_search`, the Formula path uses the function
 * names and wire types returned dynamically by `/formulas/.../tools`. The definition is already injected into the request
 * body by the recipe / Formula, so `definition == null` here and the entry only provides the execution allowlist and the echo.
 */
internal class MoonshotWebSearchTool(
    override val name: String = BUILTIN_TOOL_NAME,
    override val wireType: String = BUILTIN_WIRE_TYPE,
    private val executeCall: suspend (ToolLoopToolCall) -> String,
) : ToolRegistryEntry {
    override val scope: ToolScope = ToolScope.Web
    override val definition: ai.oriveo.community.core.tools.ToolLoopToolDefinition? = null

    override suspend fun execute(call: ToolLoopToolCall, context: ai.oriveo.community.core.tools.ToolExecutionContext): ToolExecutionOutcome =
        ToolExecutionOutcome(content = executeCall(call))

    companion object {
        const val BUILTIN_TOOL_NAME = "\$web_search"
        const val BUILTIN_WIRE_TYPE = "builtin_function"

        /**
         * The tool calls accepted on this leg include `$web_search` → web search has started (drives the activity status line).
         * Only this one builtin name counts: dynamically registered Formula tool names are outside the closed set and must not be guessed to be web search.
         */
        fun streamActivity(calls: List<ToolLoopToolCall>): ai.oriveo.community.core.model.StreamActivity? =
            if (calls.any { StreamActivitySignals.moonshotToolCall(it.function.name) != null }) {
                ai.oriveo.community.core.model.StreamActivity.WebSearch
            } else {
                null
            }

        /** Builtin form: arguments are sent back verbatim. */
        fun builtinResultContent(call: ToolLoopToolCall): String = call.function.arguments
    }
}

/**
 * Moonshot leg executor: owns the initial request produced by the builder (base messages / tools / recipe injection) and,
 * on each leg, sends the messages appended by the loop after the base messages. The stream is decoded with `SseParser`,
 * turning text / reasoning / tool_call chunks into the loop's leg events. The loop's `initialMessages` is empty: the base messages belong to this executor and never pass through the loop.
 *
 * Usage is billed per leg; the caller sums [collectedUsages] across legs (`ToolLoopUsage` has no cached_tokens).
 */
internal class MoonshotToolLoopLegRunner(
    private val client: HttpClient,
    private val json: Json,
    private val providerKind: ProviderKind,
    private val modelID: String,
    private val endpoint: String,
    private val baseBody: JsonObject,
    private val baseMessages: List<JsonElement>,
    private val requestOptions: ChatRequestOptions,
    private val identity: CapabilityEvidenceFacade.QueryIdentity?,
    private val applyAuth: HttpRequestBuilder.() -> Unit,
) : ToolLoopLegRunning {
    data class LegUsage(val promptTokens: Int, val completionTokens: Int, val cachedTokens: Int)

    private val usages = mutableListOf<LegUsage>()
    val collectedUsages: List<LegUsage> get() = usages.toList()

    override fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent> = flow {
        val body = buildLegBody(request)
        var legUsage: JsonObject? = null
        val toolDeltas = mutableListOf<ToolLoopToolCallDelta>()

        UnsupportedParamRetry.run(
            providerKind = providerKind,
            modelId = modelID,
            initialBody = body.toString(),
            requestOptions = requestOptions,
            identity = identity,
        ) { requestBodyAttempt ->
            val statement = client.preparePost(endpoint) {
                applyAuth()
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
                            (delta?.get("tool_calls") as? JsonArray)?.forEach { element ->
                                val obj = element as? JsonObject ?: return@forEach
                                val function = obj["function"] as? JsonObject
                                toolDeltas += ToolLoopToolCallDelta(
                                    index = (obj["index"] as? JsonPrimitive)?.intOrNull ?: 0,
                                    id = (obj["id"] as? JsonPrimitive)?.contentOrNull,
                                    type = (obj["type"] as? JsonPrimitive)?.contentOrNull,
                                    name = (function?.get("name") as? JsonPrimitive)?.contentOrNull,
                                    arguments = (function?.get("arguments") as? JsonPrimitive)?.contentOrNull,
                                )
                            }
                            val reasoning = (delta?.get("reasoning_content") as? JsonPrimitive)?.contentOrNull
                            if (!reasoning.isNullOrEmpty()) events += StreamEvent.Reasoning(reasoning)
                            val content = (delta?.get("content") as? JsonPrimitive)?.contentOrNull
                            if (!content.isNullOrEmpty()) events += StreamEvent.Delta(content)
                        }
                        events
                    },
                    // Placeholder Done at the end of a leg: the outer layer finishes a multi-leg run once, so it is filtered out on collect and never emitted.
                    onDone = { StreamEvent.Done(ProviderChatResult(text = "")) },
                ).collect { event ->
                    when (event) {
                        is StreamEvent.Delta -> emit(ToolLoopLegEvent.TextDelta(event.text))
                        is StreamEvent.Reasoning -> emit(ToolLoopLegEvent.ReasoningDelta(event.text))
                        else -> Unit
                    }
                }
            }
        }

        legUsage?.let { usage ->
            val collected = LegUsage(
                promptTokens = usage["prompt_tokens"]?.jsonPrimitive?.intOrNull ?: 0,
                completionTokens = usage["completion_tokens"]?.jsonPrimitive?.intOrNull ?: 0,
                cachedTokens = usage["cached_tokens"]?.jsonPrimitive?.intOrNull ?: 0,
            )
            usages += collected
            emit(ToolLoopLegEvent.Usage(ToolLoopUsage(
                promptTokens = collected.promptTokens,
                completionTokens = collected.completionTokens,
            )))
        }
        if (toolDeltas.isNotEmpty()) emit(ToolLoopLegEvent.ToolCallDeltas(toolDeltas))
    }

    /** Base messages + the messages appended by the loop; the final leg's `tool_choice: none` is written only when the body really has tools. */
    private fun buildLegBody(request: ToolLoopLegRequest): JsonObject {
        val appended = request.messages.map { moonshotMessageJson(it) }
        var body = JsonObject(baseBody + ("messages" to JsonArray(baseMessages + appended)))
        val hasTools = (body["tools"] as? JsonArray)?.isNotEmpty() == true
        if (request.toolChoice == ToolLoopToolChoice.None && hasTools) {
            body = JsonObject(body + ("tool_choice" to JsonPrimitive("none")))
        }
        return body
    }
}

/**
 * Neutral message → OpenAI-chat wire shape.
 *
 * Not a plain `encodeToJsonElement`: `ToolLoopToolCall.type` defaults to `"function"`, and a provider `Json` usually has
 * `encodeDefaults = false`, which would drop `type` entirely when a Formula call is echoed (its wireType is exactly `"function"`),
 * leaving both the continuation check and the upstream request without the field. Built explicitly here so `type` is always present.
 */
internal fun moonshotMessageJson(message: ToolLoopMessage): JsonObject = buildJsonObject {
    put("role", JsonPrimitive(message.role))
    message.content?.let { put("content", it) }
    message.reasoningContent?.let { put("reasoning_content", JsonPrimitive(it)) }
    message.toolCalls?.let { calls ->
        put("tool_calls", JsonArray(calls.map { call ->
            buildJsonObject {
                put("id", JsonPrimitive(call.id))
                put("type", JsonPrimitive(call.type))
                put("function", buildJsonObject {
                    put("name", JsonPrimitive(call.function.name))
                    put("arguments", JsonPrimitive(call.function.arguments))
                })
            }
        }))
    }
    message.toolCallId?.let { put("tool_call_id", JsonPrimitive(it)) }
    message.name?.let { put("name", JsonPrimitive(it)) }
}

/** Formula tool name and wire type: both the allowlist registration and the echoed `type` follow the dynamic `/tools` declaration. */
internal data class MoonshotFormulaToolRegistration(val name: String, val wireType: String)

internal fun moonshotFormulaRegistrations(tools: List<JsonElement>): List<MoonshotFormulaToolRegistration> =
    tools.map { element ->
        val obj = element as? JsonObject
            ?: throw ai.oriveo.community.core.model.ProviderServiceError.InvalidConfiguration("Formula tool declaration invalid.")
        val name = ((obj["function"] as? JsonObject)?.get("name") as? JsonPrimitive)?.contentOrNull
            ?: (obj["name"] as? JsonPrimitive)?.contentOrNull
            ?: throw ai.oriveo.community.core.model.ProviderServiceError.InvalidConfiguration("Formula tool declaration invalid.")
        val wireType = (obj["type"] as? JsonPrimitive)?.contentOrNull
            ?.takeIf { it.isNotBlank() }
            ?: "function"
        MoonshotFormulaToolRegistration(name = name, wireType = wireType)
    }

/** Request body for Formula Fiber (`{name, arguments}`; arguments verbatim, neither parsed nor re-serialized). */
internal fun moonshotFormulaFiberBody(call: ToolLoopToolCall): String = buildJsonObject {
    put("name", JsonPrimitive(call.function.name))
    put("arguments", JsonPrimitive(call.function.arguments))
}.toString()
