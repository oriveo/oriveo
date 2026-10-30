package ai.oriveo.community.core.search

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Address parsing result: scheme / host already lowercased, the default port is recorded as null. */
data class SearchServiceAddress(
    val scheme: String,
    val host: String,
    val port: Int?,
    val path: String,
    val query: String,
)

/**
 * Custom service form. addressClass comes from the existing safety check for local / LAN compute (after DNS resolution): public | lan | unresolved.
 * platform: ios | android | web.
 */
data class CustomSearchServiceForm(
    val name: String?,
    val address: String?,
    val protocol: String?,
    val platform: String,
    val addressClass: String?,
    val presetId: String? = null,
    val catalogAvailable: Boolean? = null,
    val presetActive: Boolean? = null,
    val manual: JsonElement? = null,
)

data class CustomSearchServiceValidation(
    val ok: Boolean,
    val errors: List<String>,
    val warnings: List<String>,
    val origin: String?,
    val requestPath: String?,
)

data class SearchKeyNormalization(val ok: Boolean, val key: String?, val error: String?)

data class CatalogOutageBehavior(val usable: Boolean, val creatable: Boolean, val presentation: String? = null)

/** Custom service : form validation, key binding origin, manual mapping validation, "same as X" snapshot, what to do when the catalog is unavailable. */
object SearchCustomService {
    val CUSTOM_PROTOCOLS = listOf("searxng", "same_as", "manual")

    /** Custom services (three protocols) carry no catalog limits, so this value is always used for timeout, still bounded by [SearchHardLimits.MAX_TIMEOUT_SEC]. */
    const val CUSTOM_TIMEOUT_SEC = 20

    /** SearXNG protocol: built into the client (not a catalog vendor), GET /search?format=json; when a key is given it is sent as Bearer. */
    val SEARXNG_SPEC: JsonObject = buildJsonObject {
        put("kind", SearchTransport.TRANSPORT_KIND)
        put("method", "GET")
        put("auth", buildJsonObject { put("kind", "bearer") })
        put(
            "query",
            buildJsonObject {
                put("field", "q")
                put("in", "query")
                put("maxChars", SearchHardLimits.MAX_QUERY_CHARS)
            },
        )
        put("count", JsonNull)
        put(
            "static",
            buildJsonObject {
                put("in", "query")
                put("params", buildJsonObject { put("format", "json") })
            },
        )
        put(
            "response",
            buildJsonObject {
                put("results", "results")
                put("title", buildJsonArray { add(JsonPrimitive("title")) })
                put("url", buildJsonArray { add(JsonPrimitive("url")) })
                put("snippet", buildJsonArray { add(JsonPrimitive("content")) })
                put("date", buildJsonArray { add(JsonPrimitive("publishedDate")) })
                put("html", true)
            },
        )
        put(
            "errors",
            buildJsonArray {
                add(
                    buildJsonObject {
                        put("status", 403)
                        put("class", "searxng_json_disabled")
                    },
                )
            },
        )
    }

    private val IDENT_PATH = Regex("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*")
    private val HEADER_NAME = Regex("[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}")
    private val BLOCKED_HEADERS = setOf(
        "host", "content-length", "content-type", "cookie", "connection", "transfer-encoding",
        "origin", "referer", "accept", "user-agent",
    )
    private val TEMPLATE_MARKERS = listOf("{{", "\${", "<%", "#{")
    private val DEFAULT_PORT = mapOf("http" to 80, "https" to 443)

    /** The web app relays through the server and may only connect to ports the SSRF guard allows; mobile is unrestricted, this is only for form validation and contract checks. */
    val WEB_ALLOWED_PORTS = listOf(80, 443, 8080, 8443)

    // JS `.` does not match \n \r U+2028 U+2029; match the whole string with matchEntire (JS ^…$ has no m flag)
    private const val ANY = "[^\\n\\r\\u2028\\u2029]"
    private val ADDRESS = Regex("([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)(\\?[^#]*)?(#$ANY*)?")
    private val HOST_PORT = Regex("(\\[[0-9A-Fa-f:.]+]|[A-Za-z0-9.-]+)(?::(\\d{1,5}))?")

    /** Address parsing: accepts only ASCII hostnames or IPs; no userinfo / fragment. Returns null = invalid. */
    fun parseServiceAddress(address: String?): SearchServiceAddress? {
        val t = SearchJson.jsTrim(address ?: return null)
        val m = ADDRESS.matchEntire(t) ?: return null
        val scheme = m.groupValues[1].lowercase()
        val authority = m.groupValues[2]
        if (m.groups[5] != null || authority.contains('@') || authority.isEmpty()) return null
        val hp = HOST_PORT.matchEntire(authority) ?: return null
        val host = hp.groupValues[1].lowercase()
        if (!host.startsWith("[") && (host.startsWith(".") || host.endsWith(".") || host.contains(".."))) return null
        var port = hp.groups[2]?.value?.toInt()
        if (port != null && (port < 1 || port > 65535)) return null
        if (port != null && DEFAULT_PORT[scheme] == port) port = null
        return SearchServiceAddress(scheme, host, port, m.groupValues[3], m.groups[4]?.value ?: "")
    }

    /** Origin a key is bound to: scheme://host[:port] (default port omitted). A path change does not clear the key, an origin change must. */
    fun keyBindingOrigin(address: String?): String? {
        val p = parseServiceAddress(address) ?: return null
        return "${p.scheme}://${p.host}${p.port?.let { ":$it" } ?: ""}"
    }

    fun addressChangeClearsKey(oldAddress: String?, newAddress: String?): Boolean =
        keyBindingOrigin(oldAddress) != keyBindingOrigin(newAddress)

    fun searxngPath(path: String?): String {
        val base = (path ?: "").replace(Regex("/+$"), "")
        return if (base.endsWith("/search")) base else "$base/search"
    }

    private fun hasTemplate(s: String?): Boolean = s != null && TEMPLATE_MARKERS.any { s.contains(it) }

    private fun identOk(e: JsonElement?): Boolean = SearchJson.string(e)?.let(IDENT_PATH::matches) == true

    /** Validate manual mapping (json_http/v1 subset): returns an array of error codes, empty = valid. */
    fun validateManualMapping(mapping: JsonElement?): List<String> {
        // JS: arrays are objects too, treated as an object with no fields; null / primitive = mapping missing
        val m: JsonObject = when (mapping) {
            is JsonObject -> mapping
            is JsonArray -> JsonObject(emptyMap())
            else -> return listOf("mapping_missing")
        }
        val errors = mutableListOf<String>()
        if (SearchJson.string(m["method"]) !in setOf("GET", "POST")) errors += "method_invalid"
        val auth = SearchJson.obj(m["auth"]) ?: JsonObject(emptyMap())
        val authKind = SearchJson.string(auth["kind"])
        if (authKind !in setOf("bearer", "header", "none")) errors += "auth_invalid"
        if (authKind == "header") {
            val name = (auth["name"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content ?: ""
            if (!HEADER_NAME.matches(name) || name.lowercase() in BLOCKED_HEADERS) errors += "header_name_invalid"
        }
        fun fieldOk(f: JsonElement?): Boolean {
            val o = SearchJson.obj(f) ?: return false
            return identOk(o["field"]) && SearchJson.string(o["in"]) in setOf("body", "query")
        }
        val query = SearchJson.obj(m["query"])
        val count = m["count"]
        if (!fieldOk(m["query"])) errors += "query_field_invalid"
        if (count != null && count != JsonNull && !fieldOk(count)) errors += "count_field_invalid"
        if (SearchJson.string(m["method"]) == "GET") {
            val staticObj = m["static"]
            if (SearchJson.string(query?.get("in")) == "body" ||
                SearchJson.string(SearchJson.obj(count)?.get("in")) == "body" ||
                (SearchJson.truthy(staticObj) && SearchJson.string(SearchJson.obj(staticObj)?.get("in")) == "body")
            ) {
                errors += "get_has_body"
            }
        }
        val paramsEl = SearchJson.obj(m["static"])?.get("params")
        val params: List<Pair<String, JsonElement>> = when (paramsEl) {
            is JsonObject -> paramsEl.entries.map { it.key to it.value }
            is JsonArray -> paramsEl.mapIndexed { i, v -> i.toString() to v }
            else -> emptyList()
        }
        if (params.size > 10) errors += "too_many_static_params"
        for ((k, v) in params) {
            val str = SearchJson.string(v)
            when {
                !IDENT_PATH.matches(k) -> errors += "static_key_invalid"
                !(SearchJson.isBoolean(v) || SearchJson.isInteger(v) || (str != null && SearchJson.codePointLength(str) <= 200)) ->
                    errors += "static_value_invalid"
                hasTemplate(str) -> errors += "template_rejected"
            }
        }
        val r = SearchJson.obj(m["response"]) ?: JsonObject(emptyMap())
        if (!identOk(r["results"])) errors += "results_path_invalid"
        for (key in listOf("title", "url", "snippet")) {
            val a = SearchJson.array(r[key])
            if (a == null || a.isEmpty() || a.size > 3 || !a.all(::identOk)) errors += "${key}_path_invalid"
        }
        for (key in listOf("site", "date")) {
            if (!r.containsKey(key)) continue
            val a = SearchJson.array(r[key])
            if (a == null || a.size > 3 || !a.all(::identOk)) errors += "${key}_path_invalid"
        }
        for (s in listOf(query?.get("field"), SearchJson.obj(count)?.get("field"), r["results"])) {
            if (hasTemplate(SearchJson.string(s))) errors += "template_rejected"
        }
        if (pathConflict(m)) errors += "path_conflict"
        return errors.distinct()
    }

    /** Two paths in the same location (body or query string) are identical, or one is a prefix of the other (a and a.b); they would overwrite each other when expanded. */
    private fun pathConflict(m: JsonObject): Boolean {
        val where = mapOf("body" to mutableListOf<String>(), "query" to mutableListOf())
        fun add(spec: JsonElement?) {
            val o = SearchJson.obj(spec) ?: return
            val field = SearchJson.string(o["field"])?.takeIf { it.isNotEmpty() } ?: return
            where[SearchJson.string(o["in"])]?.add(field)
        }
        add(m["query"])
        add(m["count"])
        val staticObj = SearchJson.obj(m["static"])
        val staticIn = SearchJson.string(staticObj?.get("in")) ?: SearchJson.string(SearchJson.obj(m["query"])?.get("in"))
        where[staticIn]?.let { list -> SearchJson.obj(staticObj?.get("params"))?.keys?.let(list::addAll) }
        return where.values.any { list ->
            list.indices.any { i -> list.indices.any { j -> i != j && (list[i] == list[j] || list[j].startsWith("${list[i]}.")) } }
        }
    }

    /**
     * Key pasted by the user (same for preset and custom): trim leading/trailing whitespace; empty → key_empty; not 1–1024 printable ASCII characters (0x21–0x7E) → key_invalid
     * (it goes into an HTTP header). The stored value is used when sending and is not modified.
     */
    fun normalizeSearchKey(raw: String?): SearchKeyNormalization {
        val key = raw?.let(SearchJson::jsTrim) ?: ""
        if (key.isEmpty()) return SearchKeyNormalization(false, null, "key_empty")
        if (key.length > 1024 || key.any { it.code !in 0x21..0x7e }) return SearchKeyNormalization(false, null, "key_invalid")
        return SearchKeyNormalization(true, key, null)
    }

    /** "Same as X": snapshot that vendor's mapping (without the host) at save time, so later catalog changes do not affect already saved services. */
    fun snapshotPresetMapping(entry: JsonObject, regionId: String?): JsonObject {
        val t = SearchJson.obj(entry["transport"]) ?: JsonObject(emptyMap())
        val regions = SearchJson.array(entry["regions"])
        val region = (
            regions?.firstOrNull { regionId != null && SearchJson.string((it as? JsonObject)?.get("id")) == regionId }
                ?: regions?.firstOrNull()
            ) as? JsonObject
        val staticSpec = SearchJson.obj(t["static"])
        val params = LinkedHashMap<String, JsonElement>().apply {
            SearchJson.obj(staticSpec?.get("params"))?.let { putAll(it) }
            SearchJson.obj(region?.get("static"))?.let { putAll(it) }
        }
        val countSpec = t["count"]?.takeIf { SearchJson.truthy(it) }
        return buildJsonObject {
            put("kind", SearchTransport.TRANSPORT_KIND)
            put("method", t["method"] ?: JsonNull)
            put("auth", t["auth"] ?: JsonObject(emptyMap()))
            put("query", t["query"] ?: JsonObject(emptyMap()))
            put("count", countSpec ?: JsonNull)
            put(
                "static",
                if (params.isEmpty()) {
                    JsonNull
                } else {
                    buildJsonObject {
                        put("in", staticSpec?.get("in") ?: SearchJson.obj(t["query"])?.get("in") ?: JsonNull)
                        put("params", JsonObject(params))
                    }
                },
            )
            put("response", t["response"] ?: JsonNull)
            put("errors", t["errors"]?.takeIf { it != JsonNull } ?: JsonArray(emptyList()))
            put(
                "snapshotOf",
                buildJsonObject {
                    put("serviceId", entry["id"] ?: JsonNull)
                    put("region", region?.get("id") ?: JsonNull)
                },
            )
        }
    }

    /** Custom service form validation; outputs ok / errors / warnings / origin / requestPath. */
    fun validateCustomSearchService(input: CustomSearchServiceForm): CustomSearchServiceValidation {
        val errors = mutableListOf<String>()
        val warnings = mutableListOf<String>()
        val name = input.name?.let(SearchJson::jsTrim) ?: ""
        if (name.isEmpty()) errors += "name_empty" else if (SearchJson.codePointLength(name) > 40) errors += "name_too_long"
        val addr = parseServiceAddress(input.address)
        when {
            addr == null -> errors += "address_invalid"
            addr.scheme !in setOf("http", "https") -> errors += "scheme_not_allowed"
            addr.query.isNotEmpty() -> errors += "address_has_query"
            else -> {
                val web = input.platform == "web"
                if (web && addr.scheme == "http") errors += "http_not_allowed_on_web"
                if (web && addr.port != null && addr.port !in WEB_ALLOWED_PORTS) errors += "port_not_allowed_on_web"
                if (web && input.addressClass == "lan") errors += "private_address_on_web"
                if (!web && addr.scheme == "http" && input.addressClass == "public") errors += "http_public_not_allowed"
                if (!web && addr.scheme == "http" && input.addressClass == "lan") warnings += "cleartext_lan"
                if (input.addressClass == "unresolved") errors += "address_unresolved"
            }
        }
        if (input.protocol !in CUSTOM_PROTOCOLS) errors += "protocol_invalid"
        if (input.protocol == "same_as" && !(input.catalogAvailable == true && input.presetActive == true)) errors += "preset_unavailable"
        if (input.protocol == "manual") errors += validateManualMapping(input.manual)
        val requestPath = if (addr != null && errors.isEmpty()) {
            if (input.protocol == "searxng") searxngPath(addr.path) else addr.path.ifEmpty { "/" }
        } else {
            null
        }
        return CustomSearchServiceValidation(
            ok = errors.isEmpty(),
            errors = errors.distinct(),
            warnings = warnings,
            origin = if (addr != null) keyBindingOrigin(input.address) else null,
            requestPath = requestPath,
        )
    }

    /**
     * Request for a custom service: spec chosen by protocol (searxng = built-in [SEARXNG_SPEC]; same_as = the [snapshotPresetMapping] taken at save time;
     * manual = manual mapping), target from address parsing (searxng appends /search to the path, others default to /). Returns null if the address is invalid or the mapping is missing.
     */
    fun customServiceSpec(protocol: String?, mapping: JsonObject?): JsonObject? = when (protocol) {
        "searxng" -> SEARXNG_SPEC
        "same_as", "manual" -> mapping
        else -> null
    }

    fun customServiceTarget(protocol: String?, address: String?): SearchTarget? {
        val addr = parseServiceAddress(address) ?: return null
        val path = if (protocol == "searxng") searxngPath(addr.path) else addr.path.ifEmpty { "/" }
        return SearchTarget(scheme = addr.scheme, host = addr.host, port = addr.port, path = path)
    }

    /** Execution timeout for a custom service (seconds). */
    val customTimeoutSec: Int get() = minOf(CUSTOM_TIMEOUT_SEC, SearchHardLimits.MAX_TIMEOUT_SEC)

    /** What happens to each kind of service when the preset catalog is unavailable (404 / signature failure / no snapshot). protocol includes preset. */
    fun catalogOutageBehavior(protocol: String, saved: Boolean, catalogAvailable: Boolean): CatalogOutageBehavior = when {
        catalogAvailable -> CatalogOutageBehavior(usable = true, creatable = true)
        protocol == "preset" -> CatalogOutageBehavior(usable = false, creatable = false, presentation = "presets_unavailable")
        protocol == "same_as" -> CatalogOutageBehavior(usable = saved, creatable = false)
        else -> CatalogOutageBehavior(usable = true, creatable = true)
    }
}
