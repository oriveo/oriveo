package ai.oriveo.community.core.search

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Hard client limits, independent of the catalog. */
object SearchHardLimits {
    const val MAX_COUNT = 10
    const val DEFAULT_COUNT = 5
    const val MAX_TIMEOUT_SEC = 60
    const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024
    const val TITLE_MAX_CHARS = 200
    const val SNIPPET_MAX_CHARS = 1000
    const val SITE_MAX_CHARS = 100
    const val DATE_MAX_CHARS = 32
    const val MAX_QUERY_CHARS = 400
}

/** Request target: scheme / host / port (null for the default port) / full path (custom services override spec.path) / site static parameter overrides. */
data class SearchTarget(
    val scheme: String,
    val host: String,
    val port: Int? = null,
    val path: String? = null,
    val static: JsonObject? = null,
)

/** Result of [SearchTransport.buildSearchRequest]: the request to send, or no request ([SearchRequestSkip]). */
sealed interface SearchBuildResult

/** The built request; body is an object (compared with JSON semantics), null for GET. headers keep their order. */
data class SearchHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: JsonObject?,
) : SearchBuildResult

/** No request; reason = query_empty (empty query, the caller treats it as "no results" and does not spend the user's money). */
data class SearchRequestSkip(val reason: String) : SearchBuildResult

data class SearchResultItem(
    val title: String,
    val url: String,
    val snippet: String,
    val site: String? = null,
    val date: String? = null,
)

sealed interface SearchParseResult {
    data class Results(val results: List<SearchResultItem>) : SearchParseResult
    data object Empty : SearchParseResult
    data class Error(val errorClass: String) : SearchParseResult
}

data class SearchErrorInput(
    val status: Int? = null,
    /** timeout | network | too_large | blocked */
    val transportFailure: String? = null,
    /** host_changed | service_withdrawn */
    val preflight: String? = null,
    /** mismatch */
    val parse: String? = null,
    val body: JsonElement? = null,
    /** Dedicated rules of a catalog entry / custom protocol (transport.errors). */
    val rules: JsonArray? = null,
    val custom: Boolean = false,
    val otherServices: Int = 0,
)

data class SearchErrorCard(val headline: String, val primaryAction: String, val secondaryAction: String? = null)

data class SearchErrorOutcome(
    val errorClass: String,
    val retryOnce: Boolean,
    val toolMessage: String,
    val card: SearchErrorCard,
)

data class SearchErrorClassDef(
    val retryOnce: Boolean,
    val toolMessage: String,
    val headline: String,
    val primaryAction: String,
)

/**
 * Restricted declarative transport json_http/v1: request building, result cleaning, error mapping.
 * Ported function by function from scripts/lib/search-transport.mjs; only extracts values, no templates, expressions or scripts.
 */
object SearchTransport {
    const val TRANSPORT_KIND = "json_http/v1"

    private sealed interface ParamRule {
        data class Enum(val values: List<JsonPrimitive>) : ParamRule
        data class IntRange(val min: Long, val max: Long) : ParamRule
    }

    /** Allowlist of static parameters the catalog may enable (key = dotted path): stops the catalog from enabling surcharge parameters. Custom services are not bound by it. */
    private val STATIC_PARAM_WHITELIST: Map<String, ParamRule> = linkedMapOf(
        "search_engine" to ParamRule.Enum(listOf(JsonPrimitive("search_std"), JsonPrimitive("search-prime"))),
        "search_intent" to ParamRule.Enum(listOf(JsonPrimitive(false))),
        "search_depth" to ParamRule.Enum(listOf(JsonPrimitive("basic"))),
        "type" to ParamRule.Enum(listOf(JsonPrimitive("auto"))),
        "max_tokens_per_page" to ParamRule.IntRange(1, 512),
        "contents.text" to ParamRule.Enum(listOf(JsonPrimitive(false))),
        "contents.highlights.maxCharacters" to ParamRule.IntRange(1, 1000),
        "format" to ParamRule.Enum(listOf(JsonPrimitive("json"))),
    )

    /** Allowlist keys → same shape as constants.staticParamWhitelist in the fixture (enum / int range), for contract test checks. */
    val staticParamWhitelistShape: Map<String, Pair<List<JsonPrimitive>?, List<Long>?>>
        get() = STATIC_PARAM_WHITELIST.mapValues { (_, r) ->
            when (r) {
                is ParamRule.Enum -> r.values to null
                is ParamRule.IntRange -> null to listOf(r.min, r.max)
            }
        }

    fun staticParamAllowed(key: String, value: JsonElement?): Boolean = when (val rule = STATIC_PARAM_WHITELIST[key]) {
        null -> false
        is ParamRule.Enum -> value is JsonPrimitive && value !is JsonNull && rule.values.any { it == value }
        is ParamRule.IntRange -> SearchJson.isInteger(value) &&
            SearchJson.safeInteger(value)?.let { it in rule.min..rule.max } == true
    }

    private fun truncateChars(s: String, max: Int): String {
        val cps = SearchJson.codePoints(s)
        if (cps.size <= max) return s
        return cps.take(max - 1).joinToString("") + "…"
    }

    private val TAG = Regex("<[^>]*>")
    private val ENTITY_REF = Regex("&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]+);")
    private val ENTITY = mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ")
    private val CONTROL = Regex("[\\u0000-\\u001f\\u007f-\\u009f]")
    private val SPACES = Regex("[${SearchJson.jsWhitespaceClass}\\u00a0\\u2028\\u2029\\u3000]+")

    /**
     * Clean text in a result: with html=true strip tags and decode entities; C0 / C1 control characters become a space; consecutive whitespace collapses to one space;
     * trim both ends; truncate by code points (append … at the end).
     */
    fun sanitizeSearchText(value: String?, html: Boolean = false, maxChars: Int): String {
        if (value == null) return ""
        var s: String = value
        if (html) {
            s = s.replace(TAG, "")
            s = ENTITY_REF.replace(s) { m ->
                val body = m.groupValues[1]
                if (body[0] == '#') {
                    val cp = if (body[1] == 'x' || body[1] == 'X') body.substring(2).toInt(16) else body.substring(1).toInt()
                    if (cp in 1..0x10ffff && cp !in 0xd800..0xdfff) String(Character.toChars(cp)) else " "
                } else {
                    ENTITY[body] ?: m.value
                }
            }
        }
        s = s.replace(CONTROL, " ")
        s = s.replace(SPACES, " ").trim(' ')
        return truncateChars(s, maxChars)
    }

    private fun firstText(item: JsonObject, paths: JsonElement?, html: Boolean, maxChars: Int): String {
        for (p in SearchJson.array(paths) ?: return "") {
            val path = SearchJson.string(p) ?: continue
            val v = SearchJson.getPath(item, path)
            val text = when {
                SearchJson.string(v) != null -> SearchJson.string(v)!!
                v is JsonArray && v.all { SearchJson.string(it) != null } -> v.joinToString(" … ") { SearchJson.string(it)!! }
                else -> ""
            }
            val clean = sanitizeSearchText(text, html, maxChars)
            if (clean.isNotEmpty()) return clean
        }
        return ""
    }

    private val ABSOLUTE_HTTP = Regex("^https?://[^${SearchJson.jsWhitespaceClass}/?#]+", RegexOption.IGNORE_CASE)

    private fun absoluteHttpUrl(e: JsonElement?): String? {
        val t = SearchJson.jsTrim(SearchJson.string(e) ?: return null)
        return t.takeIf { ABSOLUTE_HTTP.containsMatchIn(it) }
    }

    /** JS encodeURIComponent (UTF-8, uppercase hex; keeps A–Z a–z 0–9 - _ . ! ~ * ' ( )). */
    private fun encodeUriComponent(s: String): String {
        val out = StringBuilder()
        for ((i, c) in s.withIndex()) {
            if (c.isSurrogate()) {
                val paired = (c.isHighSurrogate() && i + 1 < s.length && s[i + 1].isLowSurrogate()) ||
                    (c.isLowSurrogate() && i > 0 && s[i - 1].isHighSurrogate())
                require(paired) { "URI malformed" }
            }
        }
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val ch = (b.toInt() and 0xff).toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch in "-_.!~*'()") out.append(ch)
            else out.append('%').append("%02X".format(b.toInt() and 0xff))
        }
        return out.toString()
    }

    /** Value in a query string: JS String(v). */
    private fun queryValue(v: JsonElement): String = when (v) {
        is JsonPrimitive -> v.content
        else -> v.toString()
    }

    private fun setPath(root: MutableMap<String, Any>, dotted: String, value: JsonElement) {
        val parts = dotted.split('.')
        var cur = root
        for (i in 0 until parts.size - 1) {
            @Suppress("UNCHECKED_CAST")
            cur = when (val next = cur[parts[i]]) {
                null -> linkedMapOf<String, Any>().also { cur[parts[i]] = it }
                is MutableMap<*, *> -> next as MutableMap<String, Any>
                else -> throw IllegalArgumentException("cannot set $dotted: ${parts[i]} is not an object")
            }
        }
        cur[parts.last()] = value
    }

    private fun toJson(tree: Map<String, Any>): JsonObject = JsonObject(
        tree.mapValues { (_, v) ->
            @Suppress("UNCHECKED_CAST")
            if (v is Map<*, *>) toJson(v as Map<String, Any>) else v as JsonElement
        },
    )

    /**
     * spec: json_http/v1 description (a catalog entry's transport, or a custom service's mapping). For target see [SearchTarget].
     * Outputs method / url / headers / body; body is an object (compared with JSON semantics, not bytes).
     */
    fun buildSearchRequest(spec: JsonObject, target: SearchTarget, query: String?, count: Int?, key: String?): SearchBuildResult {
        val q0 = SearchJson.obj(spec["query"]) ?: JsonObject(emptyMap())
        val maxChars = minOf(SearchJson.intValue(q0["maxChars"]) ?: SearchHardLimits.MAX_QUERY_CHARS, SearchHardLimits.MAX_QUERY_CHARS)
        val q = SearchJson.codePoints(SearchJson.jsTrim(query ?: "")).take(maxOf(maxChars, 0)).joinToString("")
        // An empty query sends no request (does not spend the user's money); the caller treats it as "no results"
        if (q.isEmpty()) return SearchRequestSkip("query_empty")
        val countSpec = SearchJson.obj(spec["count"])
        val specMax = SearchJson.intValue(countSpec?.get("max")) ?: SearchHardLimits.MAX_COUNT
        // A count that is not a positive integer (absent, 0, negative) always falls back to the default 5 ("request value || 5")
        val want = count?.takeIf { it > 0 } ?: SearchHardLimits.DEFAULT_COUNT
        val n = maxOf(1, minOf(want, specMax, SearchHardLimits.MAX_COUNT))
        val bodyTree = linkedMapOf<String, Any>()
        val queryPairs = mutableListOf<Pair<String, String>>()
        fun put(where: String?, field: String, value: JsonElement) {
            if (where == "query") queryPairs += field to queryValue(value) else setPath(bodyTree, field, value)
        }
        val queryIn = SearchJson.string(q0["in"])
        put(queryIn, SearchJson.string(q0["field"]) ?: "", JsonPrimitive(q))
        if (countSpec != null) put(SearchJson.string(countSpec["in"]), SearchJson.string(countSpec["field"]) ?: "", JsonPrimitive(n))
        val staticSpec = SearchJson.obj(spec["static"])
        val staticParams = LinkedHashMap<String, JsonElement>().apply {
            SearchJson.obj(staticSpec?.get("params"))?.let { putAll(it) }
            target.static?.let { putAll(it) }
        }
        val staticIn = SearchJson.string(staticSpec?.get("in")) ?: queryIn
        for (k in staticParams.keys.sorted()) put(staticIn, k, staticParams.getValue(k))

        val method = SearchJson.string(spec["method"]) ?: "GET"
        val port = target.port?.takeIf { it != 0 }?.let { ":$it" } ?: ""
        val path = target.path ?: SearchJson.string(spec["path"]) ?: "/"
        val qs = if (queryPairs.isEmpty()) "" else "?" + queryPairs.joinToString("&") { (k, v) ->
            "${encodeUriComponent(k)}=${encodeUriComponent(v)}"
        }
        val headers = linkedMapOf("Accept" to "application/json")
        if (method == "POST") headers["Content-Type"] = "application/json"
        if (!key.isNullOrEmpty()) {
            val auth = SearchJson.obj(spec["auth"])
            when (SearchJson.string(auth?.get("kind"))) {
                "bearer" -> headers["Authorization"] = "Bearer $key"
                "header" -> SearchJson.string(auth?.get("name"))?.let { headers[it] = key }
            }
        }
        return SearchHttpRequest(
            method = method,
            url = "${target.scheme}://${target.host}$port$path$qs",
            headers = headers,
            body = if (method == "POST") toJson(bodyTree) else null,
        )
    }

    /**
     * 2xx response → Results | Empty | Error(parse_mismatch).
     * Each item has title / url / snippet / site? / date?; items whose url is not an absolute http(s) are dropped; results of the same call are deduplicated by url; truncated by count.
     */
    fun parseSearchResponse(spec: JsonObject, body: JsonElement?, count: Int?): SearchParseResult {
        val r = SearchJson.obj(spec["response"]) ?: return SearchParseResult.Error("parse_mismatch")
        val list = SearchJson.array(SearchJson.string(r["results"])?.let { SearchJson.getPath(body, it) })
            ?: return SearchParseResult.Error("parse_mismatch")
        // Same semantics as building: a non-positive-integer becomes 5, then clamped to the hard limit
        val n = minOf(count?.takeIf { it > 0 } ?: SearchHardLimits.DEFAULT_COUNT, SearchHardLimits.MAX_COUNT)
        val seen = HashSet<String>()
        val results = mutableListOf<SearchResultItem>()
        val html = SearchJson.isTrue(r["html"])
        for (raw in list) {
            if (results.size >= n) break
            val item = raw as? JsonObject ?: continue
            var url: String? = null
            for (p in SearchJson.array(r["url"]) ?: JsonArray(emptyList())) {
                url = SearchJson.string(p)?.let { absoluteHttpUrl(SearchJson.getPath(item, it)) }
                if (url != null) break
            }
            if (url == null || !seen.add(url)) continue
            val site = firstText(item, r["site"], html, SearchHardLimits.SITE_MAX_CHARS)
            val date = firstText(item, r["date"], false, SearchHardLimits.DATE_MAX_CHARS)
            results += SearchResultItem(
                title = firstText(item, r["title"], html, SearchHardLimits.TITLE_MAX_CHARS).ifEmpty { url },
                url = url,
                snippet = firstText(item, r["snippet"], html, SearchHardLimits.SNIPPET_MAX_CHARS),
                site = site.ifEmpty { null },
                date = date.ifEmpty { null },
            )
        }
        if (list.isNotEmpty() && results.isEmpty()) return SearchParseResult.Error("parse_mismatch")
        return if (results.isNotEmpty()) SearchParseResult.Results(results) else SearchParseResult.Empty
    }

    // ───────────── Error mapping ─────────────

    val ERROR_CLASSES: Map<String, SearchErrorClassDef> = linkedMapOf(
        "auth_invalid" to SearchErrorClassDef(false, "unavailable", "key_rejected", "update_key"),
        "insufficient_balance" to SearchErrorClassDef(false, "unavailable", "insufficient_balance", "top_up"),
        "rate_limited" to SearchErrorClassDef(false, "unavailable", "rate_limited", "retry_later"),
        "timeout" to SearchErrorClassDef(false, "unavailable", "no_response", "retry"),
        "network" to SearchErrorClassDef(false, "unavailable", "no_response", "retry"),
        "upstream_unavailable" to SearchErrorClassDef(true, "unavailable", "no_response", "retry"),
        "upstream_error" to SearchErrorClassDef(false, "unavailable", "service_error", "retry"),
        "request_rejected" to SearchErrorClassDef(false, "unavailable", "service_error", "switch_service"),
        "parse_mismatch" to SearchErrorClassDef(false, "unavailable", "format_mismatch", "switch_service"),
        "searxng_json_disabled" to SearchErrorClassDef(false, "unavailable", "searxng_json_disabled", "view_setup_guide"),
        "host_changed" to SearchErrorClassDef(false, "unavailable", "host_changed", "reconfirm"),
        "service_withdrawn" to SearchErrorClassDef(false, "unavailable", "service_withdrawn", "switch_service"),
        "response_too_large" to SearchErrorClassDef(false, "unavailable", "service_error", "switch_service"),
    )

    /** Fixed text returned to the model (English, verbatim identical on all platforms). */
    val TOOL_MESSAGES: Map<String, String> = linkedMapOf(
        "no_results" to "The web search returned no results. Do not search again for this; answer from what you know and say that the search found nothing.",
        "unavailable" to "Web search is not available right now. Do not call web_search again in this reply. Answer directly and tell the user you could not search the web.",
        "cap_reached" to "The web search limit for this reply has been reached. Do not call web_search again. Answer from the results you already have.",
    )

    private fun ruleMatches(body: JsonElement?, match: JsonElement?): Boolean {
        val m = SearchJson.obj(match) ?: return match == null || match == JsonNull
        val path = SearchJson.string(m["path"]) ?: return false
        return SearchJson.getPath(body, path) == m["equals"]
    }

    fun classifySearchError(input: SearchErrorInput): SearchErrorOutcome {
        var cls: String? = when {
            input.transportFailure == "timeout" -> "timeout"
            input.transportFailure == "network" -> "network"
            input.transportFailure == "too_large" -> "response_too_large"
            // Refused to send by the local security policy (plaintext resolving to a public address, DNS rebinding, cross-origin / too many hops / invalid Location redirects): no HTTP status, retrying is useless
            input.transportFailure == "blocked" -> "request_rejected"
            input.preflight == "host_changed" -> "host_changed"
            input.preflight == "service_withdrawn" -> "service_withdrawn"
            input.parse == "mismatch" -> "parse_mismatch"
            else -> null
        }
        if (cls == null) {
            val s = input.status
            for (rule in input.rules ?: JsonArray(emptyList())) {
                val o = rule as? JsonObject ?: continue
                if (s != null && SearchJson.safeInteger(o["status"]) == s.toLong() && ruleMatches(input.body, o["match"])) {
                    cls = SearchJson.string(o["class"])
                    break
                }
            }
            if (cls == null) {
                cls = when {
                    s == 401 || s == 403 -> "auth_invalid"
                    s == 402 -> "insufficient_balance"
                    s == 429 -> "rate_limited"
                    // HTTP 408 means upstream said "did not get it in time", retried once like 502 / 503; a local timeout goes through transportFailure and is not retried
                    s == 408 || s == 502 || s == 503 -> "upstream_unavailable"
                    s != null && s >= 500 -> "upstream_error"
                    else -> "request_rejected"
                }
            }
        }
        val resolved = cls ?: "request_rejected"
        val def = ERROR_CLASSES[resolved] ?: throw IllegalArgumentException("unknown error class $resolved")
        return SearchErrorOutcome(resolved, def.retryOnce, def.toolMessage, searchErrorCard(resolved, input.custom, input.otherServices))
    }

    /** Primary / secondary actions of the error card: shared by classifySearchError and the reply wrap-up (finishSearchReply). */
    fun searchErrorCard(cls: String, custom: Boolean = false, otherServices: Int = 0): SearchErrorCard {
        val def = ERROR_CLASSES[cls] ?: throw IllegalArgumentException("unknown error class $cls")
        var primary = def.primaryAction
        // A custom service has no official link / catalog, so balance and format class primary actions become "Check settings"
        if (custom && primary in setOf("top_up", "switch_service") && cls != "service_withdrawn") primary = "check_settings"
        // A failure does not switch service automatically; when other services exist a "Switch to X" secondary action is given
        // When the local network fails, any service fails to connect equally, so no "Switch to X"
        val secondary = if (otherServices > 0 && primary != "switch_service" && cls != "network") "switch_to_other_service" else null
        return SearchErrorCard(def.headline, primary, secondary)
    }
}
