package ai.oriveo.community.core.search

import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.tools.ToolExecutionContext
import ai.oriveo.community.core.tools.ToolExecutionOutcome
import ai.oriveo.community.core.tools.ToolFailureDisposition
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolLoopToolFunction
import ai.oriveo.community.core.tools.ToolRegistryEntry
import ai.oriveo.community.core.tools.ToolScope
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/*
 * IO layer of external web search (external search service): connects the composition entry of SearchTurn.kt to this platform's executor, tool loop,
 * [D] assembly, persistence and telemetry. It only acts on what the functions output - counts, budget, numbering, facts and error cards are all decided by applySearchEvent / finishSearchReply.
 */

/** The service used for this turn's external search: identity, other switchable services, and the function that sends one request (already bound to the key and catalog entry). */
class ExternalSearchBinding(
    /** id = the local service record id (used for the source, the error card and the switch target). */
    val service: SearchTurnService,
    val otherServices: List<SearchOtherService>,
    /** "Results per request" on the service detail page; used when the model gives no count. */
    val defaultCount: Int,
    val execute: suspend (query: String, count: Int?) -> SearchCallOutcome,
    /** The service for telemetry: preset = catalog id, custom = custom (only the enum is reported, never the local id). */
    val telemetryService: String = if (service.custom) "custom" else service.id,
)

/**
 * External search input of one send (assembled by the send coordinator after resolveWebSearchState):
 * [path] = route.path; [toolCall] = tri-state of catalog evidence for tool calls; [action] = send | regenerate | edit_resend | re_search.
 */
class ExternalSearchSend(
    val path: String,
    val toolCall: String,
    val modelKey: String,
    val binding: ExternalSearchBinding?,
    val action: String = "send",
    /**
     * The reply state of this turn that an internal resend within this turn (automatic resend after window overflow recovery, etc.) keeps using: when non-null no request is sent and no charge is made; the source line and message facts keep this turn's actual values,
     * [D] is rebuilt on a separate state by reuse ([rebuildSearchDelivery]) and is not marked "reusing the previous search".
     */
    val resume: SearchReplyState? = null,
) {
    /** Internal resend within this turn: if this turn has already searched (has call records or sources) carry this turn's state forward; if not, return unchanged. */
    fun forInternalResend(state: SearchReplyState): ExternalSearchSend {
        if (state.calls.isEmpty() && state.citations.isEmpty()) return this
        return ExternalSearchSend(path, toolCall, modelKey, binding, action, resume = state)
    }
}

/** Group sources by query into reuse events (shared by resend reuse and the [D] rebuild of an internal resend). */
private fun reuseGroups(sources: List<SearchCitation>): Map<String, List<SearchResultItem>> {
    val groups = LinkedHashMap<String, MutableList<SearchResultItem>>()
    for (c in sources) {
        groups.getOrPut(c.query.orEmpty()) { mutableListOf() } +=
            SearchResultItem(title = c.title, url = c.url, snippet = c.snippet, site = c.site, date = c.date)
    }
    return groups
}

/**
 * [D] for an internal resend within this turn: rebuild the envelope from reuse events on a separate new state (for context only), this turn's reply state is unchanged. Returns null when there are no sources.
 */
fun rebuildSearchDelivery(start: SearchReplyStart, citations: List<SearchCitation>): String? {
    val groups = reuseGroups(citations.filter { it.source == EXTERNAL_SEARCH_SOURCE })
    if (groups.isEmpty()) return null
    var state = startSearchReply(start)
    return groups.map { (query, results) ->
        val step = applySearchEvent(state, SearchEvent.Reuse(query, results))
        state = step.state
        (step.effect as SearchEffect.Deliver).content
    }.joinToString("\n\n")
}

/**
 * A preset service whose key cannot be read on this device (or the reused connection was deleted): send no request and finish directly as an invalid key (primary button "Update Key").
 * A custom service's key is optional and does not go through here.
 */
fun missingKeySearchFailure(otherServices: Int): SearchExecution.Failed {
    val cls = "auth_invalid"
    val def = SearchTransport.ERROR_CLASSES.getValue(cls)
    return SearchExecution.Failed(
        SearchErrorOutcome(cls, retryOnce = false, toolMessage = def.toolMessage, card = SearchTransport.searchErrorCard(cls, otherServices = otherServices)),
        sent = false,
    )
}

/**
 * One-shot intent of "regenerate and search again" (regenerate.action = re_search): the regenerate entry records it per conversation before sending,
 * and the send coordinator takes it when assembling [ExternalSearchSend]. In memory only.
 */
object ExternalSearchReSearchIntents {
    private val conversations = ConcurrentHashMap.newKeySet<String>()

    fun mark(conversationId: String) {
        conversations += conversationId
    }

    /** Take this conversation's intent (true if there was one). */
    fun take(conversationId: String): Boolean = conversations.remove(conversationId)

    internal fun clearForTest() = conversations.clear()
}

private val EXTERNAL_SEARCH_PATHS = setOf("external_tool", "external_presearch")

/** route.path is an external search path. */
fun isExternalSearchPath(path: String?): Boolean = path in EXTERNAL_SEARCH_PATHS

/** Executor outcome → event outcome (with elapsed time). */
fun SearchExecution.toOutcome(latencyMs: Long): SearchCallOutcome = when (this) {
    is SearchExecution.Results -> SearchCallOutcome.Results(results, latencyMs)
    SearchExecution.Empty -> SearchCallOutcome.Empty(latencyMs)
    is SearchExecution.Failed -> SearchCallOutcome.Failed(outcome.errorClass, outcome.retryOnce, sent, latencyMs)
}

/** An unexpected exception thrown by the executor is handled as a network failure (the request may have been sent). */
fun unexpectedSearchFailure(custom: Boolean, otherServices: Int, latencyMs: Long): SearchCallOutcome {
    val outcome = SearchTransport.classifySearchError(
        SearchErrorInput(transportFailure = "network", custom = custom, otherServices = otherServices),
    )
    return SearchCallOutcome.Failed(outcome.errorClass, outcome.retryOnce, sent = true, latencyMs = latencyMs)
}

/**
 * Protocol adapter used by the request → protocol name in the thinking rule table (THINKING_TOOL_RULES). Several vendors on openai_chat are split by vendor;
 * the rest are passed as is, and ones not in the table are treated as unverified.
 */
fun searchThinkingProtocol(finalTransport: String?, providerKind: String?): String? {
    val t = finalTransport?.takeIf { it.isNotBlank() } ?: return null
    return when (t) {
        "openai_chat" -> when (providerKind) {
            "deepseek" -> "deepseek_chat"
            "moonshot" -> "moonshot_chat"
            "zhipu" -> "zhipu_chat"
            "qwen", "dashscope" -> "qwen_chat"
            else -> "openai_chat"
        }
        "gemini_generate" -> "gemini_generate_content"
        else -> t
    }
}

/**
 * Unified thinking.on across platforms: this turn's outgoing request really carries a reasoning parameter. Automatic injects no tier (intentValue = null, no reasoning field goes out),
 * Fast is the "fast / no thinking" tier; every other tier going out means thinking is requested.
 */
fun searchThinkingOn(reasoning: ai.oriveo.community.core.model.ReasoningMode): Boolean =
    reasoning.intentValue != null && reasoning != ai.oriveo.community.core.model.ReasoningMode.Fast

/**
 * Display state of the activity row: service name, the queries appended per call for this reply, and whether one is in flight right now.
 * After all deliver, [searching] = false and the activity row switches to "Answering from the search results" until the first character. Transient, not persisted.
 */
data class ExternalSearchActivityState(
    val serviceName: String,
    val queries: List<String>,
    val searching: Boolean,
) {
    /** Chips: at most 3 (newest at the end, the in-flight one is always included). */
    val chips: List<String> get() = queries.takeLast(MAX_CHIPS).map(::searchQueryChipText)

    companion object {
        const val MAX_CHIPS = 3
        const val CHIP_MAX_CHARS = 40
    }
}

/** Chip text: take the first non-blank line, truncate beyond 40 characters (counted by grapheme, not UTF-16 code unit) and append "…". */
fun searchQueryChipText(query: String): String {
    val line = query.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty()
    val breaks = java.text.BreakIterator.getCharacterInstance().apply { setText(line) }
    var end = 0
    repeat(ExternalSearchActivityState.CHIP_MAX_CHARS) {
        val next = breaks.following(end)
        if (next == java.text.BreakIterator.DONE) return line
        end = next
    }
    return if (end >= line.length) line else line.substring(0, end) + "…"
}

/** Activity event → next display state: a new call appends a chip; a retry of the same call does not append; deliver marks not in flight. */
fun nextExternalSearchActivity(
    previous: ExternalSearchActivityState?,
    activity: SearchActivity?,
    retry: Boolean,
): ExternalSearchActivityState? = when {
    activity == null -> previous?.copy(searching = false)
    retry && previous?.searching == true -> previous
    else -> ExternalSearchActivityState(activity.serviceName, previous?.queries.orEmpty() + activity.query, searching = true)
}

/** Persisted source → source of the composition entry (used by resend reuse and compact history records). */
fun Citation.toSearchCitation(): SearchCitation = SearchCitation(
    number = index ?: 0,
    source = source.orEmpty(),
    title = title.orEmpty(),
    url = url,
    snippet = snippet.orEmpty(),
    query = query,
    serviceId = serviceId,
    serviceName = serviceName,
    retrievedAt = retrievedAt,
    site = site,
    date = date,
)

/** Source of the composition entry → persisted source (same list as library / MCP sources, the number is written to [Citation.index]). */
fun SearchCitation.toCitation(): Citation = Citation(
    url = url,
    title = title,
    snippet = snippet,
    index = number,
    source = source,
    query = query,
    serviceId = serviceId,
    serviceName = serviceName,
    retrievedAt = retrievedAt,
    site = site,
    date = date,
)

/** Compact record of a historical assistant message: when that message has non-empty external sources, returns one line to append after the body. */
fun searchedRecordLineFor(citations: List<Citation>?): String? =
    citations?.filter { it.source == EXTERNAL_SEARCH_SOURCE }?.takeIf { it.isNotEmpty() }
        ?.let { list -> searchedRecordLine(list.map { it.toSearchCitation() }) }

const val EXTERNAL_SEARCH_SOURCE = "external_search"

/**
 * Remember in-process that "upstream for this conversation × model rejected a request with web_search": memory only, not persisted, afterwards go straight to pre-search.
 */
object SearchToolsRejectionMemory {
    private val keys = ConcurrentHashMap.newKeySet<String>()

    private fun key(conversationId: String, modelKey: String) = "$conversationId\u0000$modelKey"

    fun mark(conversationId: String, modelKey: String) {
        keys += key(conversationId, modelKey)
    }

    fun rejectedBefore(conversationId: String, modelKey: String): Boolean = key(conversationId, modelKey) in keys

    internal fun clearForTest() = keys.clear()
}

/**
 * External search driver of one reply: holds [SearchReplyState], advances by events and executes effects.
 * Only one search is in flight at a time (the composition entry does not allow concurrent calls); parallel tool_calls queue here.
 */
class SearchReplyRunner(
    initial: SearchReplyState,
    private val binding: ExternalSearchBinding,
    private val track: (SearchTelemetryEvent) -> Unit,
    /** On send gives the activity (service name + query; retry = a retry of the same call), on deliver gives null. */
    private val activity: (SearchActivity?, Boolean) -> Unit = { _, _ -> },
) {
    private val mutex = Mutex()

    @Volatile
    var state: SearchReplyState = initial
        private set

    val webResultsPresent: Boolean get() = state.webResultsPresent

    /** One search (the model calls web_search or pre-search): advances all the way to deliver, returns the content handed back to the model and the sources newly numbered by this search. */
    suspend fun search(query: String?, count: Int?): SearchEffect.Deliver = mutex.withLock {
        var step = applySearchEvent(state, SearchEvent.Call(query, count))
        state = step.state
        try {
            var effect = step.effect
            while (effect is SearchEffect.Send) {
                activity(effect.activity, effect.retry)
                val cur = checkNotNull(state.current)
                val outcome = binding.execute(cur.query, cur.count ?: binding.defaultCount)
                step = applySearchEvent(state, SearchEvent.Result(outcome))
                state = step.state
                effect = step.effect
            }
            val deliver = effect as SearchEffect.Deliver
            deliver.telemetry.forEach { track(it.withTelemetryService()) }
            deliver
        } finally {
            activity(null, false)
        }
    }

    /** Resend reuse: the external sources of the regenerated message are grouped by query and emit reuse events; returns the content to put into [D] (paragraphs separated by a blank line), null if no sources. */
    suspend fun reuse(previous: List<Citation>): String? = mutex.withLock {
        val groups = reuseGroups(previous.filter { it.source == EXTERNAL_SEARCH_SOURCE }.map { it.toSearchCitation() })
        if (groups.isEmpty()) return@withLock null
        val parts = groups.map { (query, results) ->
            val step = applySearchEvent(state, SearchEvent.Reuse(query, results))
            state = step.state
            (step.effect as SearchEffect.Deliver).content
        }
        parts.joinToString("\n\n")
    }

    /** MCP sources appearing in the loop: share one numbering allocator with external search, returns the numbers of each. */
    suspend fun otherSources(source: String, items: List<CitationItem>): List<Int> = mutex.withLock {
        val step = applySearchEvent(state, SearchEvent.OtherSources(source, items))
        state = step.state
        (step.effect as? SearchEffect.Numbers)?.numbers.orEmpty()
    }

    /** A library source newly arriving in the library loop: take the number from the shared allocator (ones arriving after a web search are placed after the web sources). */
    suspend fun libraryCitationNumber(docId: String, url: String?): Int? =
        otherSources("library", listOf(CitationItem(url = url?.takeIf { it.isNotEmpty() }, libraryKey = docId))).firstOrNull()

    /** User stopped: the in-flight one counts once (no results). Does not wait for the lock: the in-flight search is being cancelled. */
    fun stopped() {
        state = applySearchEvent(state, SearchEvent.Stopped).state
        activity(null, false)
    }

    fun finish(): SearchReplyFinish = finishSearchReply(state)

    // The composition entry reports telemetry by service.id; on this platform service.id is the local record id, swapped here for the catalog id / custom
    private fun SearchTelemetryEvent.withTelemetryService(): SearchTelemetryEvent =
        if ("service" in props) copy(props = LinkedHashMap(props).also { it["service"] = binding.telemetryService }) else this
}

/** web_search registry entry: definition taken from plan.webSearchTool; results are always neutral (not counted toward consecutive failures). */
class WebSearchToolEntry(
    private val tool: WebSearchToolDef,
    private val runner: SearchReplyRunner,
) : ToolRegistryEntry {
    override val name: String get() = tool.name
    override val scope: ToolScope get() = ToolScope.Web
    override val definition: ToolLoopToolDefinition
        get() = ToolLoopToolDefinition(function = ToolLoopToolFunction(tool.name, tool.description, tool.parameters))

    override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome {
        val args = runCatching { Json.parseToJsonElement(call.function.arguments) as? JsonObject }.getOrNull()
        val query = (args?.get("query") as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        val count = (args?.get("count") as? JsonPrimitive)?.intOrNull
        return ToolExecutionOutcome(runner.search(query, count).content)
    }

    override fun failureDisposition(error: Throwable): ToolFailureDisposition =
        ToolFailureDisposition.Neutral("search_unavailable", SearchTransport.TOOL_MESSAGES.getValue("unavailable"))
}
