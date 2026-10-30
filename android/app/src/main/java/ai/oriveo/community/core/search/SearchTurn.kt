package ai.oriveo.community.core.search

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/*
 * External web search: execution-side composition point (external search service).
 * Ported line by line from scripts/lib/search-turn.mjs (same names, same semantics); fixture shared/search-contracts/search-turn.v1.json.
 * From route.path of resolveWebSearchState all the way to the request and presentation: pre-send planning → one step per search → reply wrap-up.
 * The IO layer on each platform (executor, tool loop, [D] assembly, persistence, telemetry sending) acts only on the outputs here and never decides counts, budget, numbering, facts or error cards itself.
 */

/** Criterion for upstream rejecting tools (tools_rejected): first leg of this reply, web_search was included, the catalog did not confirm tool-call support, HTTP 400 / 422. */
val TOOLS_REJECTED_STATUSES: List<Int> = listOf(400, 422)

/** Pre-search has no tool, so the text handed to the model must not mention web_search (it goes where <oriveo-web> is in [D]). */
val PRESEARCH_MESSAGES: Map<String, String> = linkedMapOf(
    "no_results" to "A web search for this message returned no results. Answer from what you know and say that the search found nothing.",
    "unavailable" to "Web search was not available for this message. Answer directly and tell the user you could not search the web.",
    "cap_reached" to "No web results could be added for this message. Answer from what you know.",
)

/** Tool definition visible to the model; parameters is the JSON Schema as is. */
data class WebSearchToolDef(val name: String, val description: String, val parameters: JsonObject)

/** web_search tool definition (visible to the model, English, verbatim identical on all platforms; {today} = local date YYYY-MM-DD). */
val WEB_SEARCH_TOOL: WebSearchToolDef = WebSearchToolDef(
    name = "web_search",
    description = "Search the web for current information. Today is {today}. Each result has a publication date (date) when known; " +
        "the search itself happens now. For technical topics you may search once more in English. Cite results as [n] using their id; " +
        "do not write a reference list. At most 3 searches per reply.",
    parameters = buildJsonObject {
        put("type", "object")
        putJsonObject("properties") {
            putJsonObject("query") {
                put("type", "string")
                put("description", "Search query, at most 400 characters.")
            }
            putJsonObject("count") {
                put("type", "integer")
                put("description", "Number of results, 1 to 10. Default 5.")
            }
        }
        put("required", buildJsonArray { add(JsonPrimitive("query")) })
    },
)

/** No more requests once the remaining injection budget for this reply drops below this value: the envelope skeleton plus one result would not fit, so sending would only waste credit. */
const val MIN_SEARCH_BUDGET_TOKENS = 256

val RESULT_BUCKETS: List<String> = listOf("0", "1-3", "4-5", "6-10")
val LATENCY_BUCKETS: List<String> = listOf("lt_1s", "1_3s", "3_10s", "gte_10s")

private fun resultBucket(n: Int) = if (n <= 0) "0" else if (n <= 3) "1-3" else if (n <= 5) "4-5" else "6-10"

private fun latencyBucket(ms: Long) = if (ms < 1000) "lt_1s" else if (ms < 3000) "1_3s" else if (ms < 10000) "3_10s" else "gte_10s"

private val EXTERNAL_PATHS = setOf("external_tool", "external_presearch")

// ───────────── Pre-send planning ─────────────

/** Current search service; protocol = catalog | searxng | same_as | manual. */
data class SearchTurnService(val id: String, val name: String, val protocol: String, val custom: Boolean = false)

data class SearchThinking(val on: Boolean = false, val protocol: String? = null, val continuationStateAvailable: Boolean? = null)

/** Upstream rejection on this leg: HTTP status + which leg (0 = first leg). */
data class SearchUpstreamRejection(val status: Int, val leg: Int)

/** action = send | regenerate | edit_resend | re_search. */
data class SearchRegenerate(val action: String = "send", val previousResultsPersisted: Boolean = false)

data class SearchTurnPlanInput(
    /** resolveWebSearchState.route.path. */
    val path: String,
    val service: SearchTurnService? = null,
    val toolCall: String? = null,
    /** The path field is unused (overridden by path). */
    val host: SearchToolHostInput = SearchToolHostInput(),
    val thinking: SearchThinking = SearchThinking(),
    val upstreamRejection: SearchUpstreamRejection? = null,
    /** This conversation × model has already been rejected during this run (remembered in memory only, not persisted). */
    val toolsRejectedBefore: Boolean = false,
    val regenerate: SearchRegenerate = SearchRegenerate(),
    val userText: String? = null,
    val b: Int? = null,
    /** Local date YYYY-MM-DD. */
    val today: String = "",
)

data class SearchPresearch(val query: String, val count: Int)

/** Telemetry event; prop values are String / Boolean. */
data class SearchTelemetryEvent(val event: String, val props: Map<String, Any>)

/** The part of the plan that startSearchReply needs. */
data class SearchReplyPlan(val path: String, val fallbackReason: String?, val noticeOnce: Boolean)

data class SearchTurnPlan(
    val path: String,
    val fallbackReason: String?,
    val noticeOnce: Boolean,
    val requestHasNativeSearchFields: Boolean,
    val requestHasWebSearchTool: Boolean,
    val toolHost: SearchToolHost,
    val webSearchTool: WebSearchToolDef?,
    val presearch: SearchPresearch?,
    val reuse: Boolean,
    val budget: SearchInjectionBudget?,
    val writeToolConfirm: String,
    val telemetry: List<SearchTelemetryEvent>,
) {
    val replyPlan: SearchReplyPlan get() = SearchReplyPlan(path, fallbackReason, noticeOnce)
}

/** Pre-send planning (called once per send, and once more after upstream rejects tools and we switch path). */
fun planSearchTurn(input: SearchTurnPlanInput): SearchTurnPlan {
    val host = input.host
    if (input.path !in EXTERNAL_PATHS) {
        val turn = resolveSearchTurnPath(SearchTurnInput(path = input.path))
        return SearchTurnPlan(
            path = turn.path,
            fallbackReason = turn.fallbackReason,
            noticeOnce = turn.noticeOnce,
            requestHasNativeSearchFields = turn.requestHasNativeSearchFields,
            requestHasWebSearchTool = turn.requestHasWebSearchTool,
            toolHost = resolveSearchToolHost(host.copy(path = input.path)),
            webSearchTool = null,
            presearch = null,
            reuse = false,
            budget = null,
            writeToolConfirm = "n/a",
            telemetry = emptyList(),
        )
    }
    if (input.service == null) throw IllegalArgumentException("external path without service")
    val thinking = input.thinking
    val toolHost = if (input.path == "external_tool") resolveSearchToolHost(host.copy(path = "external_tool")) else null
    val rej = input.upstreamRejection
    val rejectedNow = rej != null && rej.leg == 0 && rej.status in TOOLS_REJECTED_STATUSES && input.toolCall != "supported"
    // This conversation × model was already rejected once during this run: go straight to pre-search with no further prompt (remembered in memory only, not persisted)
    val rejectedBefore = input.toolsRejectedBefore && input.toolCall != "supported"
    val turn = resolveSearchTurnPath(
        SearchTurnInput(
            path = input.path,
            thinkingOn = thinking.on,
            // A protocol that has not been verified always goes to pre-search while thinking is on ("protocols we cannot pin down")
            thinkingWithTools = THINKING_TOOL_RULES[thinking.protocol]?.thinkingWithTools ?: "presearch",
            continuationStateAvailable = thinking.continuationStateAvailable != false,
            upstreamRejectedTools = rejectedNow || rejectedBefore,
            hostMaxSteps = toolHost?.maxSteps ?: 0,
        ),
    )
    val reuse = regenerateSearchPolicy(input.regenerate.action, input.regenerate.previousResultsPersisted).reusePrevious
    val toolPath = turn.path == "external_tool" && !reuse
    return SearchTurnPlan(
        path = turn.path,
        fallbackReason = turn.fallbackReason,
        noticeOnce = turn.noticeOnce && rejectedNow,
        requestHasNativeSearchFields = turn.requestHasNativeSearchFields,
        requestHasWebSearchTool = toolPath,
        toolHost = if (toolPath && toolHost != null) toolHost else resolveSearchToolHost(host.copy(path = "external_presearch")),
        webSearchTool = if (toolPath) WEB_SEARCH_TOOL.copy(description = WEB_SEARCH_TOOL.description.replace("{today}", input.today)) else null,
        presearch = if (turn.path == "external_presearch" && !reuse) SearchPresearch(input.userText.orEmpty(), 5) else null,
        reuse = reuse,
        budget = searchInjectionBudget(input.b),
        // When web results enter the context this turn, MCP write tools force "this time only", which applies to pre-search as well
        writeToolConfirm = if (host.mcp) "once_when_web_results_present" else "n/a",
        telemetry = turn.fallbackReason?.let {
            listOf(SearchTelemetryEvent("search_fallback_presearch", mapOf("reason" to it)))
        }.orEmpty(),
    )
}

// ───────────── Search state of one reply ─────────────

data class SearchOtherService(val id: String, val name: String, val isDefault: Boolean = false)

data class SearchReplyStart(
    val plan: SearchReplyPlan,
    val service: SearchTurnService,
    val otherServices: List<SearchOtherService> = emptyList(),
    val b: Int? = null,
    val rhoHi: Double,
    val retrievedAt: String,
    /** Sources in this message already numbered before the search (library <entry citation>), sharing one allocator with external search. */
    val priorBatches: List<CitationBatch> = emptyList(),
)

data class SearchCitationAllocator(val keys: Map<String, Int>, val next: Int)

/** A search in flight; reused = resend reuse (no request sent). */
data class SearchCallInFlight(
    val query: String,
    val count: Int? = null,
    val requests: Int = 0,
    val attempts: Int = 0,
    val latencyMs: Long = 0,
    val reused: Boolean = false,
)

/** A finished search; outcome = results | empty | cap_reached | <errorClass>. */
data class SearchCallRecord(
    val query: String,
    val outcome: String,
    val delivered: Int,
    val requests: Int,
    val errorClass: String?,
    val reused: Boolean = false,
)

/** Source (for persistence and the source card); when source = external_search, query / service* / retrievedAt all have values. */
data class SearchCitation(
    val number: Int,
    val source: String,
    val title: String,
    val url: String,
    val snippet: String = "",
    val query: String? = null,
    val serviceId: String? = null,
    val serviceName: String? = null,
    val retrievedAt: String? = null,
    val site: String? = null,
    val date: String? = null,
)

/** path = tool | presearch. */
data class SearchReplyState(
    val path: String,
    val notice: String?,
    val service: SearchTurnService,
    val otherServices: List<SearchOtherService>,
    val b: Int?,
    val rhoHi: Double,
    val retrievedAt: String,
    val requestsSent: Int,
    val usedTokens: Int,
    val allocator: SearchCitationAllocator,
    val current: SearchCallInFlight?,
    val calls: List<SearchCallRecord>,
    val citations: List<SearchCitation>,
    val webResultsPresent: Boolean,
)

fun startSearchReply(input: SearchReplyStart): SearchReplyState {
    val keys = LinkedHashMap<String, Int>()
    var next = 1
    for (batch in input.priorBatches) {
        for (item in batch.items) {
            val k = citationKey(item)
            if (k !in keys) keys[k] = next++
        }
    }
    return SearchReplyState(
        path = if (input.plan.path == "external_presearch") "presearch" else "tool",
        notice = if (input.plan.noticeOnce) input.plan.fallbackReason else null,
        service = input.service,
        otherServices = input.otherServices,
        b = input.b,
        rhoHi = input.rhoHi,
        retrievedAt = input.retrievedAt,
        requestsSent = 0,
        usedTokens = 0,
        allocator = SearchCitationAllocator(keys, next),
        current = null,
        calls = emptyList(),
        citations = emptyList(),
        webResultsPresent = false,
    )
}

/** One outcome of the executor. */
sealed interface SearchCallOutcome {
    val latencyMs: Long?

    data class Results(val results: List<SearchResultItem>, override val latencyMs: Long? = null) : SearchCallOutcome
    data class Empty(override val latencyMs: Long? = null) : SearchCallOutcome

    /** sent = false: nothing was sent (e.g. precheck host_changed), does not count as a request. */
    data class Failed(
        val errorClass: String,
        val retryOnce: Boolean = false,
        val sent: Boolean = true,
        override val latencyMs: Long? = null,
    ) : SearchCallOutcome
}

sealed interface SearchEvent {
    /** The model called web_search / pre-search starts. */
    data class Call(val query: String?, val count: Int? = null) : SearchEvent

    /** The executor returned. */
    data class Result(val outcome: SearchCallOutcome) : SearchEvent

    /** Resend reuse: rebuilt from the citations already persisted for that message, no request sent. */
    data class Reuse(val query: String, val results: List<SearchResultItem>) : SearchEvent

    /** MCP sources appearing in the loop, sharing the numbering. */
    data class OtherSources(val source: String, val items: List<CitationItem>) : SearchEvent

    /** User stopped: the in-flight request was already sent, counted once (no results). */
    data object Stopped : SearchEvent
}

/** Activity row: kind = external_search. */
data class SearchActivity(val kind: String, val serviceName: String, val query: String)

sealed interface SearchEffect {
    data class Send(val retry: Boolean, val activity: SearchActivity) : SearchEffect
    data class Deliver(
        val content: String,
        val citations: List<SearchCitation>,
        val webResultsPresent: Boolean,
        val telemetry: List<SearchTelemetryEvent>,
    ) : SearchEffect
    data class Numbers(val numbers: List<Int>) : SearchEffect
    data object None : SearchEffect
}

data class SearchStep(val state: SearchReplyState, val effect: SearchEffect)

private fun messages(state: SearchReplyState): Map<String, String> =
    if (state.path == "presearch") PRESEARCH_MESSAGES else SearchTransport.TOOL_MESSAGES

private data class Delivered(val state: SearchReplyState, val delivered: Int, val content: String, val citations: List<SearchCitation>)

private fun deliverResults(state: SearchReplyState, query: String, results: List<SearchResultItem>): Delivered {
    // URLs already numbered in this message are not given to the model again (they are already in the context); only new results get numbers
    val fresh = mutableListOf<SearchResultItem>()
    val seen = HashSet<String>()
    for (r in results) {
        val k = citationKey(CitationItem(url = r.url))
        if (k in state.allocator.keys || !seen.add(k)) continue
        fresh += r
    }
    val budgetTokens = budgetForNextSearch(state.b, state.usedTokens)
    val fit = if (fresh.isNotEmpty()) {
        fitWebResults(WebFitInput(state.service.name, query, state.retrievedAt, fresh, state.allocator.next, budgetTokens, state.rhoHi))
    } else {
        null
    }
    val envelope = fit?.envelope
        ?: return Delivered(state, 0, messages(state).getValue(if (fresh.isNotEmpty()) "cap_reached" else "no_results"), emptyList())
    val keys = LinkedHashMap(state.allocator.keys)
    val citations = fit.ids.mapIndexed { i, id ->
        val r = fresh[i]
        keys[citationKey(CitationItem(url = r.url))] = id
        SearchCitation(
            number = id,
            source = "external_search",
            title = r.title,
            url = r.url,
            snippet = r.snippet,
            query = query,
            serviceId = state.service.id,
            serviceName = state.service.name,
            retrievedAt = state.retrievedAt,
            site = r.site?.takeIf { it.isNotEmpty() },
            date = r.date?.takeIf { it.isNotEmpty() },
        )
    }
    return Delivered(
        state = state.copy(
            usedTokens = state.usedTokens + fit.estimatedTokens,
            allocator = SearchCitationAllocator(keys, state.allocator.next + fit.ids.size),
            citations = state.citations + citations,
            webResultsPresent = true,
        ),
        delivered = citations.size,
        content = envelope,
        citations = citations,
    )
}

private fun finishCall(state: SearchReplyState, outcome: SearchCallOutcome): SearchStep {
    val cur = state.current ?: throw IllegalStateException("finish without call")
    var s = state.copy(current = null)
    var delivered = 0
    val content: String
    var citations = emptyList<SearchCitation>()
    val recorded: String
    when (outcome) {
        is SearchCallOutcome.Results -> {
            val r = deliverResults(s, cur.query, outcome.results)
            s = r.state
            delivered = r.delivered
            content = r.content
            citations = r.citations
            recorded = if (delivered > 0) "results" else "empty"
        }
        is SearchCallOutcome.Empty -> {
            content = messages(s).getValue("no_results")
            recorded = "empty"
        }
        is SearchCallOutcome.Failed -> {
            content = messages(s).getValue("unavailable")
            recorded = outcome.errorClass
        }
    }
    val errorClass = (outcome as? SearchCallOutcome.Failed)?.errorClass
    s = s.copy(calls = s.calls + SearchCallRecord(cur.query, recorded, delivered, cur.requests, errorClass, cur.reused))
    val telemetry = if (cur.reused) {
        emptyList()
    } else {
        listOf(
            SearchTelemetryEvent(
                "search_executed",
                linkedMapOf(
                    "service" to if (s.service.custom) "custom" else s.service.id,
                    "protocol" to s.service.protocol,
                    "path" to s.path,
                    "result_bucket" to resultBucket(delivered),
                    "latency_bucket" to latencyBucket(cur.latencyMs),
                    "error_class" to (errorClass ?: "none"),
                    "retried" to (cur.attempts > 1),
                ),
            ),
        )
    }
    return SearchStep(s, SearchEffect.Deliver(content, citations, s.webResultsPresent, telemetry))
}

/** One step: advance the state by event and return what the IO layer should do (send a request / hand back to the model / number / nothing). */
fun applySearchEvent(state: SearchReplyState, event: SearchEvent): SearchStep {
    when (event) {
        is SearchEvent.OtherSources -> {
            val keys = LinkedHashMap(state.allocator.keys)
            var next = state.allocator.next
            val numbers = event.items.map { item -> keys.getOrPut(citationKey(item)) { next++ } }
            return SearchStep(state.copy(allocator = SearchCitationAllocator(keys, next)), SearchEffect.Numbers(numbers))
        }
        SearchEvent.Stopped -> {
            val cur = state.current ?: return SearchStep(state, SearchEffect.None)
            val s = state.copy(
                current = null,
                requestsSent = state.requestsSent + 1,
                calls = state.calls + SearchCallRecord(cur.query, "empty", 0, cur.requests + 1, null),
            )
            return SearchStep(s, SearchEffect.None)
        }
        is SearchEvent.Reuse -> {
            val s = state.copy(current = SearchCallInFlight(query = event.query, reused = true))
            return finishCall(s, SearchCallOutcome.Results(event.results))
        }
        is SearchEvent.Call -> {
            check(state.current == null) { "call while another call is in flight" }
            val query = SearchJson.jsTrim(event.query.orEmpty())
            // An empty query sends no request and does not count as a search (query_empty)
            if (query.isEmpty()) {
                return SearchStep(state, SearchEffect.Deliver(messages(state).getValue("no_results"), emptyList(), state.webResultsPresent, emptyList()))
            }
            val noBudget = budgetForNextSearch(state.b, state.usedTokens) < MIN_SEARCH_BUDGET_TOKENS
            if (state.requestsSent >= SearchCallLimits.MAX_SEARCH_REQUESTS_PER_REPLY || noBudget) {
                // Over the cap or the injection budget of this reply is used up: no request, no charge (cap_reached)
                val s = state.copy(calls = state.calls + SearchCallRecord(query, "cap_reached", 0, 0, null))
                return SearchStep(s, SearchEffect.Deliver(messages(state).getValue("cap_reached"), emptyList(), state.webResultsPresent, emptyList()))
            }
            val s = state.copy(current = SearchCallInFlight(query = query, count = event.count))
            return SearchStep(s, SearchEffect.Send(false, SearchActivity("external_search", state.service.name, query)))
        }
        is SearchEvent.Result -> {
            val current = checkNotNull(state.current) { "result without call" }
            val o = event.outcome
            val sent = (o as? SearchCallOutcome.Failed)?.sent ?: true
            val cur = current.copy(
                attempts = current.attempts + 1,
                requests = current.requests + if (sent) 1 else 0,
                latencyMs = current.latencyMs + (o.latencyMs ?: 0),
            )
            val s = state.copy(current = cur, requestsSent = state.requestsSent + if (sent) 1 else 0)
            val canRetry = o is SearchCallOutcome.Failed && o.retryOnce &&
                cur.attempts <= SearchCallLimits.MAX_RETRIES_PER_CALL &&
                s.requestsSent < SearchCallLimits.MAX_SEARCH_REQUESTS_PER_REPLY
            if (canRetry) return SearchStep(s, SearchEffect.Send(true, SearchActivity("external_search", s.service.name, cur.query)))
            return finishCall(s, o)
        }
    }
}

// ───────────── Reply wrap-up ─────────────

/** Source line; reused = all from resend reuse (no new request, no new charge), writes "Reusing the previous search". */
data class SearchSourcesLine(
    val searchCount: Int,
    val serviceName: String,
    val sourceCount: Int,
    val reused: Boolean,
    val custom: Boolean,
)

data class SearchSwitchTarget(val id: String, val name: String)

data class SearchReplyErrorCard(
    val errorClass: String,
    val headline: String,
    val primaryAction: String,
    val secondaryAction: String?,
    val serviceName: String,
    val switchTo: SearchSwitchTarget?,
)

data class SearchReplyFinish(
    val facts: SearchFacts,
    val sourcesLine: SearchSourcesLine?,
    val errorCard: SearchReplyErrorCard?,
    val notice: String?,
    val citations: List<SearchCitation>,
    val webResultsPresent: Boolean,
)

/** Reply wrap-up: message facts, source line, error card, sources to persist. */
fun finishSearchReply(state: SearchReplyState): SearchReplyFinish {
    val calls = state.calls.map { SearchCallFact(it.outcome, it.delivered) }
    val facts = if (state.path == "presearch") {
        summarizeSearchFacts(path = "external_presearch", webOn = true, presearch = calls.firstOrNull(), serviceName = state.service.name)
    } else {
        summarizeSearchFacts(path = "external_tool", webOn = true, calls = calls, serviceName = state.service.name)
    }
    val sourcesLine = if (facts.searchCount > 0 && facts.state != "failed") {
        SearchSourcesLine(facts.searchCount, state.service.name, facts.sourceCount, state.calls.all { it.reused }, state.service.custom)
    } else {
        null
    }
    var errorCard: SearchReplyErrorCard? = null
    if (facts.state == "failed") {
        val last = state.calls.last { it.errorClass != null }
        val errorClass = last.errorClass!!
        val card = SearchTransport.searchErrorCard(errorClass, state.service.custom, state.otherServices.size)
        val other = state.otherServices.firstOrNull { it.isDefault } ?: state.otherServices.firstOrNull()
        errorCard = SearchReplyErrorCard(
            errorClass = errorClass,
            headline = card.headline,
            primaryAction = card.primaryAction,
            secondaryAction = card.secondaryAction,
            serviceName = state.service.name,
            switchTo = if (card.secondaryAction == "switch_to_other_service" && other != null) SearchSwitchTarget(other.id, other.name) else null,
        )
    }
    return SearchReplyFinish(facts, sourcesLine, errorCard, state.notice, state.citations, state.webResultsPresent)
}

/**
 * Compact record of a historical assistant message: derived from the persisted external_search sources, containing only the query, title and URL, no snippet.
 * Appended after that message's body with a blank line in between; returns null when there are no external sources.
 */
fun searchedRecordLine(citations: List<SearchCitation>?): String? {
    val groups = LinkedHashMap<String?, MutableList<String>>()
    for (c in citations.orEmpty()) {
        if (c.source != "external_search") continue
        groups.getOrPut(c.query) { mutableListOf() } += "${c.title} (${c.url})"
    }
    if (groups.isEmpty()) return null
    return "Web searches used for this reply (titles and URLs only): " +
        groups.entries.joinToString("; ") { (query, items) -> "\"$query\" → ${items.joinToString(", ")}" }
}
