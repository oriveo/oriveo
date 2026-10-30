package ai.oriveo.community.core.search

import com.google.crypto.tink.subtle.Ed25519Verify
import java.util.Base64
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Canonicalization failure (e.g. a non-safe integer in the catalog); [code] matches the error key in the shared fixtures. */
class CanonicalJsonException(val code: String, message: String) : IllegalArgumentException(message)

data class CatalogSignatureCheck(val ok: Boolean, val reason: String?)

/** State of a single service after adoption: active carries client-clamped limits, withdrawn carries none. */
data class CatalogServiceState(
    val id: String,
    val status: String,
    val limits: CatalogLimits? = null,
)

data class CatalogLimits(val timeoutSec: Int, val maxCount: Int)

data class CatalogSnapshot(val revision: Long, val services: List<CatalogServiceState>)

data class CatalogAdoptionState(val maxSeenRevision: Long, val current: CatalogSnapshot?)

data class CatalogSkippedEntry(val id: String?, val reason: String)

data class CatalogAcceptResult(
    val accepted: Boolean,
    val reason: String?,
    val source: String?,
    val maxSeenRevision: Long,
    val current: CatalogSnapshot?,
    val skipped: List<CatalogSkippedEntry> = emptyList(),
)

data class CatalogRegionLinks(
    val homepage: String?,
    val docs: String?,
    val terms: String?,
    val keyHelp: String?,
    val pricing: String?,
)

/**
 * External web search catalog search-catalog/v1: canonical JSON, Ed25519 signatures, entry validation and client adoption rules
 *. Ported function by function from scripts/lib/search-catalog.mjs.
 */
object SearchCatalog {
    const val CATALOG_SCHEMA = "search-catalog/v1"

    private val ID = Regex("[a-z][a-z0-9_]{1,31}")
    private val HOSTNAME = Regex("(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}")
    private val HTTPS = Regex("^https://[^${SearchJson.jsWhitespaceClass}/?#]+")
    private val DATE = Regex("\\d{4}-\\d{2}-\\d{2}")
    private val REGION_URL_KEYS = listOf("docs", "pricing", "keyHelp")

    /**
     * Canonical JSON (signature input): object keys in ascending UTF-16 code unit order, no whitespace, strings escaped like JSON.stringify;
     * numbers must be safe integers (prices in the catalog are always strings), otherwise throws [CanonicalJsonException]. Arrays keep their order.
     */
    fun canonicalCatalogJson(value: JsonElement): String = StringBuilder().also { appendCanonical(it, value) }.toString()

    private fun appendCanonical(out: StringBuilder, value: JsonElement) {
        when (value) {
            JsonNull -> out.append("null")
            is JsonPrimitive -> when {
                value.isString -> appendJsonString(out, value.content)
                value.content == "true" || value.content == "false" -> out.append(value.content)
                else -> {
                    val n = SearchJson.safeInteger(value)
                        ?: throw CanonicalJsonException("non_integer_number", "non-integer number in catalog: ${value.content}")
                    out.append(n.toString())
                }
            }
            is JsonArray -> {
                out.append('[')
                value.forEachIndexed { i, e ->
                    if (i > 0) out.append(',')
                    appendCanonical(out, e)
                }
                out.append(']')
            }
            is JsonObject -> {
                out.append('{')
                SearchJson.sortedKeys(value).forEachIndexed { i, k ->
                    if (i > 0) out.append(',')
                    appendJsonString(out, k)
                    out.append(':')
                    appendCanonical(out, value.getValue(k))
                }
                out.append('}')
            }
        }
    }

    /** Same as JSON.stringify: only escapes " \ and U+0000–U+001F (short forms first, the rest as lowercase \u00xx); lone surrogates are written as \udxxx. */
    private fun appendJsonString(out: StringBuilder, s: String) {
        out.append('"')
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '\b' -> out.append("\\b")
                c == '\u000C' -> out.append("\\f")
                c == '\n' -> out.append("\\n")
                c == '\r' -> out.append("\\r")
                c == '\t' -> out.append("\\t")
                c.code < 0x20 -> out.append("\\u%04x".format(c.code))
                c.isHighSurrogate() && i + 1 < s.length && s[i + 1].isLowSurrogate() -> {
                    out.append(c).append(s[i + 1])
                    i += 1
                }
                c.isSurrogate() -> out.append("\\u%04x".format(c.code))
                else -> out.append(c)
            }
            i += 1
        }
        out.append('"')
    }

    private fun signingPayload(doc: JsonObject): ByteArray =
        canonicalCatalogJson(JsonObject(doc.filterKeys { it != "signature" })).toByteArray(Charsets.UTF_8)

    /** trustedKeys: keyId → base64 of the 32-byte raw Ed25519 public key (built into the client). */
    fun verifyCatalogSignature(doc: JsonElement?, trustedKeys: Map<String, String>): CatalogSignatureCheck {
        val s = SearchJson.obj(SearchJson.obj(doc)?.get("signature"))
        if (s == null || SearchJson.string(s["alg"]) != "ed25519" || SearchJson.string(s["value"]) == null) {
            return CatalogSignatureCheck(false, "signature_missing")
        }
        val keyId = (s["keyId"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
        val key = keyId?.let { trustedKeys[it] }?.takeIf { it.isNotEmpty() }
            ?: return CatalogSignatureCheck(false, "signature_unknown_key")
        val ok = try {
            val raw = Base64.getMimeDecoder().decode(key)
            require(raw.size == 32) { "ed25519 public key must be 32 bytes" }
            val sig = Base64.getMimeDecoder().decode(SearchJson.string(s["value"]))
            Ed25519Verify(raw).verify(sig, signingPayload(doc as JsonObject))
            true
        } catch (_: Exception) {
            false
        }
        return if (ok) CatalogSignatureCheck(true, null) else CatalogSignatureCheck(false, "signature_invalid")
    }

    /** The string JS produces when coercing a value in regex test / `?? ''` contexts. */
    private fun coerce(e: JsonElement?): String = when (e) {
        null, JsonNull -> ""
        is JsonPrimitive -> e.content
        is JsonArray -> e.joinToString(",") { if (it is JsonNull) "" else coerce(it) }
        is JsonObject -> "[object Object]"
    }

    private fun httpsOk(e: JsonElement?): Boolean = HTTPS.containsMatchIn(coerce(e))

    private fun validTransport(t: JsonElement?): String? {
        val o = SearchJson.obj(t)
        if (o == null || SearchJson.string(o["kind"]) != SearchTransport.TRANSPORT_KIND) return "unsupported_transport"
        if (SearchJson.string(o["method"]) !in setOf("GET", "POST")) return "transport_invalid"
        val path = SearchJson.string(o["path"])
        if (path == null || !path.startsWith("/")) return "transport_invalid"
        if (SearchJson.string(SearchJson.obj(o["auth"])?.get("kind")) !in setOf("bearer", "header")) return "transport_invalid"
        val query = SearchJson.obj(o["query"])
        if (!SearchJson.truthy(query?.get("field")) || SearchJson.string(query?.get("in")) !in setOf("body", "query")) {
            return "transport_invalid"
        }
        val response = SearchJson.obj(o["response"])
        if (!SearchJson.truthy(response?.get("results")) || response?.get("url") !is JsonArray || response?.get("title") !is JsonArray) {
            return "transport_invalid"
        }
        val params = SearchJson.obj(SearchJson.obj(o["static"])?.get("params"))
        params?.forEach { (k, v) -> if (!SearchTransport.staticParamAllowed(k, v)) return "static_param_not_allowed" }
        // Dedicated-error rules: status code 400–599, class name in the closed set, match is plain string equality; an entry that fails is skipped whole so platforms don't each invent a fallback for unknown classes
        if (o.containsKey("errors")) {
            val rules = o["errors"] as? JsonArray ?: return "transport_invalid"
            for (re in rules) {
                val r = re as? JsonObject ?: return "transport_invalid"
                val status = SearchJson.safeInteger(r["status"])
                if (status == null || status < 400 || status > 599) return "transport_invalid"
                if (SearchJson.string(r["class"])?.let { it in SearchTransport.ERROR_CLASSES } != true) return "transport_invalid"
                val match = r["match"]
                if (match != null && match != JsonNull) {
                    val m = match as? JsonObject ?: return "transport_invalid"
                    if (SearchJson.string(m["path"]).isNullOrEmpty() || SearchJson.string(m["equals"]) == null) return "transport_invalid"
                }
            }
        }
        return null
    }

    /** Validate a single entry: null = usable, otherwise the reason it is skipped (only this entry is skipped, the whole catalog is not rejected). */
    fun validateCatalogEntry(entry: JsonElement?): String? {
        val e = SearchJson.obj(entry) ?: return "entry_invalid"
        if (!ID.matches(coerce(e["id"]))) return "entry_invalid"
        if (SearchJson.truthy(e["tombstone"])) {
            val at = SearchJson.string(SearchJson.obj(e["tombstone"])?.get("at"))
            return if (at != null && DATE.matches(at)) null else "entry_invalid"
        }
        if (SearchJson.string(e["displayName"]).isNullOrEmpty()) return "entry_invalid"
        if (SearchJson.string(e["group"]) !in setOf("domestic", "overseas")) return "entry_invalid"
        val urls = SearchJson.obj(e["urls"])
        for (k in listOf("homepage", "docs", "terms", "keyHelp")) if (!httpsOk(urls?.get(k))) return "entry_invalid"
        if (!httpsOk(SearchJson.obj(e["pricing"])?.get("sourceUrl"))) return "entry_invalid"
        val regions = SearchJson.array(e["regions"])
        if (regions == null || regions.isEmpty()) return "entry_invalid"
        for (re in regions) {
            val r = SearchJson.obj(re) ?: return "host_invalid"
            if (!ID.matches(coerce(r["id"])) || !HOSTNAME.matches(coerce(r["host"]))) return "host_invalid"
            SearchJson.obj(r["static"])?.forEach { (k, v) ->
                if (!SearchTransport.staticParamAllowed(k, v)) return "static_param_not_allowed"
            }
            // Site-level links are optional; only known keys are validated and unknown keys are ignored (adding keys later must not make old clients skip the entry)
            if (r.containsKey("urls")) {
                val ru = SearchJson.obj(r["urls"]) ?: return "entry_invalid"
                for (k in REGION_URL_KEYS) if (ru.containsKey(k) && !httpsOk(ru[k])) return "entry_invalid"
            }
        }
        validTransport(e["transport"])?.let { return it }
        val timeout = SearchJson.obj(e["limits"])?.get("timeoutSec")
        if (!SearchJson.isInteger(timeout) || (SearchJson.safeInteger(timeout) ?: Long.MAX_VALUE) < 1) return "entry_invalid"
        if (SearchJson.string(e["citationStorage"]) !in setOf("full", "urlTitleOnly")) return "entry_invalid"
        val trust = SearchJson.obj(e["trust"])
        val evidence = SearchJson.array(trust?.get("evidence"))
        if (SearchJson.string(trust?.get("entity")) == null || evidence == null || evidence.isEmpty() ||
            !evidence.all(::httpsOk) || !DATE.matches(coerce(trust?.get("reviewedAt")))
        ) {
            return "trust_invalid"
        }
        if (SearchJson.truthy(e["reuse"])) {
            val reuse = SearchJson.obj(e["reuse"])
            if (SearchJson.string(reuse?.get("providerKind")) == null) return "entry_invalid"
            SearchJson.obj(reuse?.get("regionByConnectionHost"))?.forEach { (host, region) ->
                val known = regions.any { (it as? JsonObject)?.get("id").let { id -> id is JsonPrimitive && id.isString && id == region } }
                if (!HOSTNAME.matches(host) || !known) return "entry_invalid"
            }
        }
        return null
    }

    /** Hard client-side limits: whatever the catalog offers is clamped to these. Only call for entries that passed validation. */
    fun clampedLimits(entry: JsonObject): CatalogLimits {
        val timeout = SearchJson.safeInteger(SearchJson.obj(entry["limits"])?.get("timeoutSec")) ?: Long.MAX_VALUE
        val countMax = SearchJson.safeInteger(SearchJson.obj(SearchJson.obj(entry["transport"])?.get("count"))?.get("max"))
            ?: SearchHardLimits.MAX_COUNT.toLong()
        return CatalogLimits(
            timeoutSec = minOf(timeout, SearchHardLimits.MAX_TIMEOUT_SEC.toLong()).toInt(),
            maxCount = minOf(countMax, SearchHardLimits.MAX_COUNT.toLong()).toInt(),
        )
    }

    /**
     * Adopt a catalog. source: network | cache | builtin.
     * Rules: signature fails → not adopted, previous one kept; revision below the highest seen locally → not adopted (rollback protection, built-in snapshot included);
     * equal → unchanged; entries validated one by one, an invalid entry is only skipped; tombstone → withdrawn, immediately stop sending keys to that service.
     */
    fun acceptSearchCatalog(
        state: CatalogAdoptionState,
        incoming: JsonElement?,
        source: String,
        trustedKeys: Map<String, String>,
    ): CatalogAcceptResult {
        fun keep(reason: String) = CatalogAcceptResult(false, reason, null, state.maxSeenRevision, state.current)
        val doc = SearchJson.obj(incoming)
        if (doc == null || SearchJson.string(doc["schema"]) != CATALOG_SCHEMA) return keep("schema_mismatch")
        val revision = SearchJson.safeInteger(doc["revision"])
        if (revision == null || revision < 1) return keep("revision_invalid")
        val sig = verifyCatalogSignature(doc, trustedKeys)
        if (!sig.ok) return keep(sig.reason ?: "signature_invalid")
        if (revision < state.maxSeenRevision) return keep("revision_rollback")
        if (state.current != null && revision == state.current.revision) return keep("unchanged")
        val services = mutableListOf<CatalogServiceState>()
        val skipped = mutableListOf<CatalogSkippedEntry>()
        for (e in SearchJson.array(doc["services"]) ?: JsonArray(emptyList())) {
            val reason = validateCatalogEntry(e)
            if (reason != null) {
                skipped += CatalogSkippedEntry(SearchJson.string(SearchJson.obj(e)?.get("id")), reason)
                continue
            }
            val o = e as JsonObject
            val id = SearchJson.string(o["id"])!!
            services += if (SearchJson.truthy(o["tombstone"])) {
                CatalogServiceState(id, "withdrawn")
            } else {
                CatalogServiceState(id, "active", clampedLimits(o))
            }
        }
        return CatalogAcceptResult(
            accepted = true,
            reason = null,
            source = source,
            maxSeenRevision = maxOf(state.maxSeenRevision, revision),
            current = CatalogSnapshot(revision, services),
            skipped = skipped,
        )
    }

    /** When reusing a model connection, pick the site by connection address (Kimi .cn / .ai); an address not in the table = not reusable. */
    fun regionForConnection(entry: JsonObject, connectionBaseUrl: String?): String? {
        val host = (connectionBaseUrl ?: "").replace(Regex("^https?://", RegexOption.IGNORE_CASE), "")
            .split(Regex("[/:?#]"))[0].lowercase()
        val table = SearchJson.obj(SearchJson.obj(entry["reuse"])?.get("regionByConnectionHost"))
        return SearchJson.string(table?.get(host))
    }

    private fun regionOf(entry: JsonObject?, regionId: String?): JsonObject? =
        SearchJson.array(entry?.get("regions"))?.firstOrNull {
            regionId != null && SearchJson.string((it as? JsonObject)?.get("id")) == regionId
        } as? JsonObject

    /**
     * Host check before sending a key: the host bound to the stored service differs from the host of that site in the current catalog → host_changed (key not sent, re-confirmation required);
     * entry withdrawn → service_withdrawn (stop sending keys).
     */
    fun presetHostCheck(boundHost: String?, entry: JsonObject?, regionId: String?, withdrawn: Boolean = false): String {
        if (withdrawn || SearchJson.truthy(entry?.get("tombstone"))) return "service_withdrawn"
        val region = regionOf(entry, regionId) ?: return "service_withdrawn"
        return if (boundHost != null && SearchJson.string(region["host"]) == boundHost) "ok" else "host_changed"
    }

    /**
     * Official links to show for a site: docs / pricing / keyHelp first take the site's `regions[].urls`, falling back key by key to the entry level
     * (`urls.docs` / `pricing.sourceUrl` / `urls.keyHelp`); homepage / terms exist only at entry level. Site not found = all entry level.
     * Only call for entries that passed validation.
     */
    fun regionLinks(entry: JsonObject, regionId: String?): CatalogRegionLinks {
        val own = SearchJson.obj(regionOf(entry, regionId)?.get("urls"))
        val urls = SearchJson.obj(entry["urls"])
        return CatalogRegionLinks(
            homepage = SearchJson.string(urls?.get("homepage")),
            docs = SearchJson.string(own?.get("docs")) ?: SearchJson.string(urls?.get("docs")),
            terms = SearchJson.string(urls?.get("terms")),
            keyHelp = SearchJson.string(own?.get("keyHelp")) ?: SearchJson.string(urls?.get("keyHelp")),
            pricing = SearchJson.string(own?.get("pricing"))
                ?: SearchJson.string(SearchJson.obj(entry["pricing"])?.get("sourceUrl")),
        )
    }

    /** Request target of a preset service for a site: HTTPS only, host from the catalog site, site static overrides entry static. Returns null if the site does not exist. */
    fun presetTarget(entry: JsonObject, regionId: String?): SearchTarget? {
        val region = regionOf(entry, regionId) ?: return null
        val host = SearchJson.string(region["host"]) ?: return null
        return SearchTarget(scheme = "https", host = host, static = SearchJson.obj(region["static"]))
    }

    /**
     * What to do with a ?view=search fetch result: 200 → adopt (hand to [acceptSearchCatalog]);
     * 404 → withdraw_presets (the whole preset block shows "unavailable", cache and built-in snapshot included; a flag is stored locally and persists across launches until a 200 is received and adopted;
     * custom services are unaffected); 304, any other status (including 400 from an old Server), network error → keep (keep the current one).
     */
    fun catalogFetchAction(status: Int? = null, transportFailure: String? = null): String = when {
        transportFailure != null -> "keep"
        status == 200 -> "adopt"
        status == 404 -> "withdraw_presets"
        else -> "keep"
    }

    /** Look up an entry in the catalog body by id (the caller stores the original catalog text). */
    fun entryById(doc: JsonElement?, id: String): JsonObject? =
        SearchJson.array(SearchJson.obj(doc)?.get("services"))?.firstOrNull {
            SearchJson.string((it as? JsonObject)?.get("id")) == id
        } as? JsonObject
}
