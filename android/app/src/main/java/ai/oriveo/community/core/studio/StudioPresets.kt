package ai.oriveo.community.core.studio

import android.content.Context
import java.io.InputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Client side of studio_presets.v1: envelope decoding, locale resolution, the bundled
 * offline snapshot and the refresh decision. Pure functions only.
 */
object StudioPresets {
    data class Group(val id: String, val order: Long, val displayName: String)

    data class Sample(val url: String, val width: Long, val height: Long, val sha256: String)

    data class Style(
        val id: String,
        val group: String,
        val order: Long,
        val featured: Boolean,
        val displayName: String,
        val description: String,
        val promptFragment: String,
        val placeholderColor: String?,
        val sample: Sample?,
    )

    data class Effect(
        val id: String,
        val group: String,
        val order: Long,
        val displayName: String,
        val promptFragment: String,
        val swatch: List<String>,
    )

    data class Dropped(val kind: String, val id: String?, val reason: String)

    data class Presets(
        val revision: String,
        val locale: String,
        val styleGroups: List<Group>,
        val effectGroups: List<Group>,
        val styles: List<Style>,
        val effects: List<Effect>,
        val dropped: List<Dropped>,
    )

    enum class DecodeError(val wire: String) {
        INVALID_ENVELOPE("invalid_envelope"),
        UNSUPPORTED_CONTRACT("unsupported_contract"),
    }

    sealed interface DecodeResult {
        data class Success(val presets: Presets) : DecodeResult
        data class Failure(val error: DecodeError) : DecodeResult
    }

    data class Cache(val locale: String, val revision: String, val etag: String?, val checkedAtMs: Long)

    data class RefreshPlan(val fetch: Boolean, val ifNoneMatch: String?)

    /** One HTTP outcome; status 0 = transport failure, body = raw response text. */
    data class Response(val status: Int, val etag: String?, val body: String?)

    enum class Outcome(val wire: String) {
        NOT_MODIFIED("not_modified"),
        UNCHANGED("unchanged"),
        REPLACED("replaced"),
        FAILED("failed"),
        INVALID("invalid"),

        /** Store only: the 6 hour window said not to fetch. */
        THROTTLED("throttled"),
    }

    data class ApplyResult(val outcome: Outcome, val cache: Cache?, val bodyReplaced: Boolean)

    const val CONTRACT_ID = "studio_presets.v1"
    const val SNAPSHOT_ASSET = "studio/studio_presets_snapshot.v1.json"
    const val REFRESH_INTERVAL_MS = 6L * 3600 * 1000
    private const val DEFAULT_FRAGMENT_MAX_CHARS = 160L

    /** 2^53 - 1: integers must be exactly representable on every end (JS Number.isSafeInteger). */
    private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
    private val hexColor = Regex("#[0-9A-Fa-f]{6}")
    private val sha256Hex = Regex("[0-9a-f]{64}")

    // ---------- JSON helpers mirroring the reference predicates ----------

    private fun JsonElement?.asObject(): JsonObject? = this as? JsonObject

    private fun JsonElement?.nonEmptyString(): String? =
        (this as? JsonPrimitive)?.takeIf { it.isString && it.content.isNotEmpty() }?.content

    private fun JsonElement?.isString(): Boolean = (this as? JsonPrimitive)?.isString == true

    /**
     * JSON number with an integral value within +-(2^53 - 1) (1.5, booleans, strings and
     * out-of-range numbers are not integers).
     */
    private fun JsonElement?.integer(): Long? {
        val p = this as? JsonPrimitive ?: return null
        if (p.isString || p is JsonNull) return null
        val value = p.content.toLongOrNull() ?: run {
            val d = p.content.toDoubleOrNull() ?: return null
            if (!d.isFinite() || d != Math.floor(d) || d < -MAX_SAFE_INTEGER.toDouble() || d > MAX_SAFE_INTEGER.toDouble()) return null
            d.toLong()
        }
        return value.takeIf { it in -MAX_SAFE_INTEGER..MAX_SAFE_INTEGER }
    }

    private fun JsonElement?.positiveInt(): Long? = integer()?.takeIf { it > 0 }

    private fun codePoints(text: String): Int = text.codePointCount(0, text.length)

    // ---------- Locale ----------

    /** Exact (case-insensitive, `_` = `-`) → zh by script, then region → language subtag → en. */
    fun resolveLocale(locales: List<String>, tag: String?): String {
        // Only ASCII whitespace is trimmed (each platform's trim() strips a different Unicode set).
        val t = tag?.trim { it == '\t' || it == '\n' || it == '\u000B' || it == '\u000C' || it == '\r' || it == ' ' }
            ?.replace('_', '-') ?: ""
        if (t.isEmpty()) return "en"
        val lower = t.lowercase()
        locales.firstOrNull { it.lowercase() == lower }?.let { return it }
        val parts = lower.split('-')
        if (parts[0] == "zh") {
            val rest = parts.drop(1)
            if ("hant" in rest) return "zh-Hant"
            if ("hans" in rest) return "zh-Hans"
            return if (rest.any { it == "tw" || it == "hk" || it == "mo" }) "zh-Hant" else "zh-Hans"
        }
        return locales.firstOrNull { it.lowercase().split('-')[0] == parts[0] } ?: "en"
    }

    /** Offline snapshot → the envelope the Server would send for [tag], samples reduced to placeholderColor. */
    fun localize(snapshot: JsonObject, tag: String?): JsonObject {
        val locales = (snapshot["locales"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            ?: emptyList()
        val locale = resolveLocale(locales, tag)
        fun pick(m: JsonElement?): JsonElement? {
            val map = m.asObject() ?: return null
            return map[locale]?.takeIf { it.isString() } ?: map["en"]
        }
        fun named(g: JsonElement, extra: Map<String, JsonElement?> = emptyMap()): JsonElement {
            val obj = g.asObject() ?: return g
            val out = LinkedHashMap<String, JsonElement>(obj)
            out.remove("displayName")
            pick(obj["displayName"])?.let { out["displayName"] = it }
            for ((key, value) in extra) {
                out.remove(key)
                if (value != null) out[key] = value
            }
            return JsonObject(out)
        }
        fun list(key: String, map: (JsonElement) -> JsonElement): JsonElement? = (snapshot[key] as? JsonArray)?.let { JsonArray(it.map(map)) }
        val data = LinkedHashMap<String, JsonElement>()
        snapshot["contractId"]?.let { data["contractId"] = it }
        snapshot["revision"]?.let { data["revision"] = it }
        data["locale"] = JsonPrimitive(locale)
        snapshot["limits"]?.let { data["limits"] = it }
        list("styleGroups") { named(it) }?.let { data["styleGroups"] = it }
        list("effectGroups") { named(it) }?.let { data["effectGroups"] = it }
        list("styles") { s ->
            val obj = s.asObject()
            val placeholder = obj?.get("sample").asObject()?.get("placeholderColor")
            named(
                s,
                mapOf(
                    "description" to pick(obj?.get("description")),
                    "sample" to JsonObject(placeholder?.let { mapOf("placeholderColor" to it) } ?: emptyMap()),
                ),
            )
        }?.let { data["styles"] = it }
        list("effects") { named(it) }?.let { data["effects"] = it }
        return JsonObject(mapOf("code" to JsonPrimitive(0), "message" to JsonPrimitive("ok"), "data" to JsonObject(data)))
    }

    /** Bundled snapshot text (the committed asset copy) → presets for [tag]; offline = decode(localize(snapshot, tag)). */
    fun parseSnapshot(raw: String, tag: String?): DecodeResult {
        val snapshot = parseJson(raw).asObject() ?: return DecodeResult.Failure(DecodeError.INVALID_ENVELOPE)
        return decode(localize(snapshot, tag))
    }

    internal fun assetReader(context: Context): () -> String? = snapshotReader(context.assets::open)

    /** Production snapshot loader: opens [SNAPSHOT_ASSET] through [open] and reads it as UTF-8. */
    internal fun snapshotReader(open: (path: String) -> InputStream): () -> String? = {
        open(SNAPSHOT_ASSET).bufferedReader(Charsets.UTF_8).use { it.readText() }
    }

    // ---------- Decoding ----------

    private fun parseJson(raw: String?): JsonElement? =
        raw?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() }

    /** Raw `{code,data,message}` response text → presets; bad entries are dropped one by one and reported. */
    fun decode(raw: String?): DecodeResult = decode(parseJson(raw))

    fun decode(envelope: JsonElement?): DecodeResult {
        val env = envelope.asObject()
        val d = if (env != null && env["code"].integer() == 0L) env["data"].asObject() else null
        d ?: return DecodeResult.Failure(DecodeError.INVALID_ENVELOPE)
        if (d["contractId"].nonEmptyString() != CONTRACT_ID) return DecodeResult.Failure(DecodeError.UNSUPPORTED_CONTRACT)
        val revision = d["revision"].nonEmptyString()
        val locale = d["locale"].nonEmptyString()
        val styles = d["styles"] as? JsonArray
        val effects = d["effects"] as? JsonArray
        if (revision == null || locale == null || styles == null || effects == null) {
            return DecodeResult.Failure(DecodeError.INVALID_ENVELOPE)
        }
        val maxFragment = d["limits"].asObject()?.get("promptFragmentMaxChars").positiveInt() ?: DEFAULT_FRAGMENT_MAX_CHARS
        val styleGroups = decodeGroups(d["styleGroups"])
        val effectGroups = decodeGroups(d["effectGroups"])
        val styleDropped = mutableListOf<Dropped>()
        val effectDropped = mutableListOf<Dropped>()
        val decodedStyles = decodeEntries("style", styles, styleGroups, maxFragment, styleDropped, ::styleOf)
        val decodedEffects = decodeEntries("effect", effects, effectGroups, maxFragment, effectDropped, ::effectOf)
        return DecodeResult.Success(
            Presets(
                revision = revision,
                locale = locale,
                styleGroups = styleGroups,
                effectGroups = effectGroups,
                styles = decodedStyles,
                effects = decodedEffects,
                dropped = styleDropped + effectDropped,
            ),
        )
    }

    private fun decodeGroups(list: JsonElement?): List<Group> {
        val seen = HashSet<String>()
        val out = mutableListOf<Group>()
        for (element in list as? JsonArray ?: JsonArray(emptyList())) {
            val g = element.asObject() ?: continue
            val id = g["id"].nonEmptyString() ?: continue
            val order = g["order"].integer() ?: continue
            val displayName = g["displayName"].nonEmptyString() ?: continue
            if (!seen.add(id)) continue
            out += Group(id, order, displayName)
        }
        // sortedBy is stable: ties keep input order.
        return out.sortedBy { it.order }
    }

    private fun decodeSample(raw: JsonElement?): Sample? {
        val s = raw.asObject() ?: return null
        val url = s["url"].nonEmptyString() ?: return null
        val width = s["width"].positiveInt() ?: return null
        val height = s["height"].positiveInt() ?: return null
        val sha = (s["sha256"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        if (!sha256Hex.matches(sha)) return null
        return Sample(url, width, height, sha)
    }

    private class Fields(val e: JsonObject, val id: String, val group: String, val order: Long, val displayName: String, val promptFragment: String)

    private fun styleOf(f: Fields): Style {
        val sample = f.e["sample"].asObject()
        val color = (sample?.get("placeholderColor") as? JsonPrimitive)?.takeIf { it.isString }?.content
        return Style(
            id = f.id,
            group = f.group,
            order = f.order,
            featured = (f.e["featured"] as? JsonPrimitive)?.let { !it.isString && it !is JsonNull && it.content == "true" } == true,
            displayName = f.displayName,
            description = (f.e["description"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "",
            promptFragment = f.promptFragment,
            placeholderColor = color?.takeIf { hexColor.matches(it) },
            sample = decodeSample(sample),
        )
    }

    private fun effectOf(f: Fields): Effect = Effect(
        id = f.id,
        group = f.group,
        order = f.order,
        displayName = f.displayName,
        promptFragment = f.promptFragment,
        swatch = (f.e["swatch"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.takeIf { c -> hexColor.matches(c) } }
            ?: emptyList(),
    )

    private fun <T> decodeEntries(
        kind: String,
        list: JsonArray,
        groups: List<Group>,
        maxFragment: Long,
        dropped: MutableList<Dropped>,
        build: (Fields) -> T,
    ): List<T> {
        val groupOrder = groups.associate { it.id to it.order }
        val seen = HashSet<String>()
        val kept = mutableListOf<Pair<Fields, T>>()
        for (element in list) {
            val e = element.asObject()
            val id = e?.get("id").nonEmptyString()
            val order = e?.get("order").integer()
            val displayName = e?.get("displayName").nonEmptyString()
            val fragment = e?.get("promptFragment").nonEmptyString()
            val group = (e?.get("group") as? JsonPrimitive)?.takeIf { it.isString }?.content
            val badDescription = kind == "style" && e?.containsKey("description") == true && !e["description"].isString()
            val reason = when {
                e == null || id == null || order == null || displayName == null || fragment == null || badDescription -> "invalid_field"
                codePoints(fragment) > maxFragment -> "fragment_too_long"
                group == null || group !in groupOrder -> "unknown_group"
                id in seen -> "duplicate_id"
                else -> null
            }
            if (reason != null) {
                dropped += Dropped(kind, id, reason)
                continue
            }
            seen += id!!
            val fields = Fields(e!!, id, group!!, order!!, displayName!!, fragment!!)
            kept += fields to build(fields)
        }
        // Stable sort by (group order, order); ties keep input position.
        return kept.sortedWith(compareBy<Pair<Fields, T>>({ groupOrder.getValue(it.first.group) }, { it.first.order })).map { it.second }
    }

    // ---------- Refresh ----------

    /** At most every [REFRESH_INTERVAL_MS] per locale; a clock that went back refetches. */
    fun planRefresh(cache: Cache?, locale: String, nowMs: Long): RefreshPlan {
        if (cache == null || cache.locale != locale) return RefreshPlan(fetch = true, ifNoneMatch = null)
        val age = nowMs - cache.checkedAtMs
        if (age in 0 until REFRESH_INTERVAL_MS) return RefreshPlan(fetch = false, ifNoneMatch = null)
        return RefreshPlan(fetch = true, ifNoneMatch = cache.etag)
    }

    /** Applies one response; failures never touch the cache nor checkedAtMs. */
    fun applyResponse(cache: Cache?, locale: String, nowMs: Long, response: Response): ApplyResult {
        val sameLocale = cache != null && cache.locale == locale
        if (response.status == 304 && sameLocale) {
            return ApplyResult(Outcome.NOT_MODIFIED, cache!!.copy(checkedAtMs = nowMs), bodyReplaced = false)
        }
        if (response.status != 200) return ApplyResult(Outcome.FAILED, cache, bodyReplaced = false)
        val decoded = decode(response.body) as? DecodeResult.Success
            ?: return ApplyResult(Outcome.INVALID, cache, bodyReplaced = false)
        if (sameLocale && cache!!.revision == decoded.presets.revision) {
            return ApplyResult(Outcome.UNCHANGED, cache.copy(checkedAtMs = nowMs), bodyReplaced = false)
        }
        return ApplyResult(
            Outcome.REPLACED,
            Cache(locale = locale, revision = decoded.presets.revision, etag = response.etag, checkedAtMs = nowMs),
            bodyReplaced = true,
        )
    }
}
