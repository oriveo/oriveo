package ai.oriveo.community.core.provider

import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** One group of unit prices in pricingV2 (main currency unit such as USD / 1M tokens); null = not provided. */
data class PricingV2Rates(
    val input: Double? = null,
    val output: Double? = null,
    val cacheRead: Double? = null,
    val cacheWrite5m: Double? = null,
    val cacheWrite1h: Double? = null,
)

data class PricingV2Tier(
    val aboveInputTokens: Long,
    val incremental: Boolean,
    /** Keys given by the tier; cacheWritePerMToken applies to both 5m and 1h. */
    val rates: PricingV2Rates,
)

data class PricingV2Window(
    /** Raw timezone string; a window that cannot be parsed is skipped when estimating. */
    val timezone: String,
    /** null = every day. */
    val days: Set<DayOfWeek>?,
    val startMinute: Int,
    val endMinute: Int,
    val multiplier: Double?,
    val rates: PricingV2Rates,
)

data class PricingV2(
    val currencyCode: String?,
    val unit: String,
    val base: PricingV2Rates?,
    val contextTiers: List<PricingV2Tier>,
    val timeWindows: List<PricingV2Window>,
    /** Per-unit price (when unit is per_image / per_second), schema key perUnit; null for per-token pricing. */
    val perUnit: Double? = null,
)

/** Five token buckets. uncachedInput excludes any cached portion. */
data class PricingV2Usage(
    val uncachedInput: Long,
    val cacheRead: Long,
    val cacheWrite5m: Long,
    val cacheWrite1h: Long,
    val output: Long,
)

sealed interface PricingV2Estimate {
    data class Estimated(val amount: Double, val currencyCode: String?) : PricingV2Estimate
    data object Unavailable : PricingV2Estimate
    data object NotApplicable : PricingV2Estimate
}

/**
 * Price v2 parsing and estimation (shared fixture pricing-v2-estimate.v1).
 * holidayCalendar and regionSurcharges do not take part in estimation.
 */
object PricingV2Estimator {

    private const val CACHE_READ_FALLBACK = 0.5
    private const val CACHE_WRITE_5M_FALLBACK = 1.25
    private const val CACHE_WRITE_1H_FALLBACK = 2.0

    /** Strict parse against the shared schema `$defs/pricingV2`: any violation treats the whole entry as missing (null) and leaves the model's other fields untouched. */
    fun parse(raw: JsonElement?): PricingV2? = runCatching { parseOrThrow(raw) }.getOrNull()

    fun estimate(pricing: PricingV2, usage: PricingV2Usage, at: Instant): PricingV2Estimate {
        if (pricing.unit != "per_token") return PricingV2Estimate.NotApplicable
        val base = pricing.base ?: return PricingV2Estimate.Unavailable
        if (base.input == null || base.output == null) return PricingV2Estimate.Unavailable

        val window = pricing.timeWindows.firstOrNull { it.matches(at) }
        val tiers = pricing.contextTiers.sortedBy { it.aboveInputTokens }
        val baseRates = resolve(base, null, window)
        val tierRates = tiers.map { resolve(base, it.rates, window) }

        val totalInput = usage.cacheRead + usage.cacheWrite5m + usage.cacheWrite1h + usage.uncachedInput
        val selected = tiers.indexOfLast { totalInput > it.aboveInputTokens }
        val top = if (selected >= 0) tierRates[selected] else baseRates

        val amount = if (selected >= 0 && tiers[selected].incremental) {
            // Inputs are laid out as one token line: cache read -> write 5m -> write 1h -> uncached, priced segment by segment by the tier they fall in
            val segments = listOf<Pair<Long, (Resolved) -> Double>>(
                usage.cacheRead to { r -> r.cacheRead },
                usage.cacheWrite5m to { r -> r.cacheWrite5m },
                usage.cacheWrite1h to { r -> r.cacheWrite1h },
                usage.uncachedInput to { r -> r.input },
            )
            var cursor = 0L
            var sum = 0.0
            for ((count, rateOf) in segments) {
                val start = cursor
                val end = cursor + count
                cursor = end
                // Tier boundary: token ordinal k (1-based) is in tier i when k > aboveInputTokens(i)
                var bandStart = start
                for (i in -1 until tiers.size) {
                    val upper = if (i + 1 < tiers.size) tiers[i + 1].aboveInputTokens else Long.MAX_VALUE
                    val bandEnd = minOf(end, upper)
                    if (bandEnd > bandStart) {
                        val rates = if (i >= 0) tierRates[i] else baseRates
                        sum += (bandEnd - bandStart) * rateOf(rates)
                        bandStart = bandEnd
                    }
                    if (bandStart >= end) break
                }
            }
            sum + usage.output * top.output
        } else {
            usage.uncachedInput * top.input +
                usage.cacheRead * top.cacheRead +
                usage.cacheWrite5m * top.cacheWrite5m +
                usage.cacheWrite1h * top.cacheWrite1h +
                usage.output * top.output
        }
        return PricingV2Estimate.Estimated(amount / 1_000_000, pricing.currencyCode)
    }

    private data class Resolved(
        val input: Double,
        val output: Double,
        val cacheRead: Double,
        val cacheWrite5m: Double,
        val cacheWrite1h: Double,
    )

    /** base -> tier override -> a missing cache price falls back to that tier's input price -> apply the time-of-day window. */
    private fun resolve(base: PricingV2Rates, tier: PricingV2Rates?, window: PricingV2Window?): Resolved {
        val input = tier?.input ?: base.input!!
        val output = tier?.output ?: base.output!!
        var resolved = Resolved(
            input = input,
            output = output,
            cacheRead = tier?.cacheRead ?: base.cacheRead ?: (input * CACHE_READ_FALLBACK),
            cacheWrite5m = tier?.cacheWrite5m ?: base.cacheWrite5m ?: (input * CACHE_WRITE_5M_FALLBACK),
            cacheWrite1h = tier?.cacheWrite1h ?: base.cacheWrite1h ?: (input * CACHE_WRITE_1H_FALLBACK),
        )
        if (window != null) {
            val m = window.multiplier
            resolved = if (m != null) {
                Resolved(
                    resolved.input * m,
                    resolved.output * m,
                    resolved.cacheRead * m,
                    resolved.cacheWrite5m * m,
                    resolved.cacheWrite1h * m,
                )
            } else {
                Resolved(
                    input = window.rates.input ?: resolved.input,
                    output = window.rates.output ?: resolved.output,
                    cacheRead = window.rates.cacheRead ?: resolved.cacheRead,
                    cacheWrite5m = window.rates.cacheWrite5m ?: resolved.cacheWrite5m,
                    cacheWrite1h = window.rates.cacheWrite1h ?: resolved.cacheWrite1h,
                )
            }
        }
        return resolved
    }

    private fun PricingV2Window.matches(at: Instant): Boolean {
        val zone = runCatching { ZoneId.of(timezone) }.getOrNull() ?: return false
        val local = at.atZone(zone)
        val minute = local.hour * 60 + local.minute
        val today = local.dayOfWeek
        fun onDay(day: DayOfWeek) = days == null || day in days
        return if (endMinute > startMinute) {
            minute >= startMinute && minute < endMinute && onDay(today)
        } else {
            (minute >= startMinute && onDay(today)) || (minute < endMinute && onDay(today.minus(1)))
        }
    }

    // -- Parsing --
    // Android has no runtime schema validation, so this is the only gate: accept only shapes matching
    // `$defs/pricingV2` in shared/model-contracts/metadata_payload.v2.schema.json; any violation drops the whole pricingV2.

    private class Malformed : RuntimeException()

    private val TOP_KEYS = setOf("currencyCode", "unit", "base", "cache", "contextTiers", "timeWindows", "regionSurcharges", "perUnit")
    private val BASE_KEYS = setOf("inputPerMToken", "outputPerMToken")
    private val CACHE_KEYS = setOf("readPerMToken", "writes")
    private val WRITE_KEYS = setOf("ttl", "perMToken")
    private val TIER_KEYS = setOf(
        "aboveInputTokens", "semantics", "inputPerMToken", "outputPerMToken", "cacheReadPerMToken", "cacheWritePerMToken",
    )
    private val WINDOW_KEYS = setOf(
        "timezone", "days", "start", "end", "inputPerMToken", "outputPerMToken", "cacheReadPerMToken", "multiplier",
        "holidayCalendar",
    )
    private val REGION_KEYS = setOf("regionScope", "multiplier")
    private val UNITS = setOf("per_token", "per_image", "per_second")
    private val HOLIDAY_CALENDARS = setOf("cn_statutory")
    private val DAYS = mapOf(
        "monday" to DayOfWeek.MONDAY, "tuesday" to DayOfWeek.TUESDAY, "wednesday" to DayOfWeek.WEDNESDAY,
        "thursday" to DayOfWeek.THURSDAY, "friday" to DayOfWeek.FRIDAY, "saturday" to DayOfWeek.SATURDAY,
        "sunday" to DayOfWeek.SUNDAY,
    )
    private val START_PATTERN = Regex("""^([01][0-9]|2[0-3]):[0-5][0-9]$""")
    private val END_PATTERN = Regex("""^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$""")

    private fun parseOrThrow(raw: JsonElement?): PricingV2? {
        if (raw == null || raw is JsonNull) return null
        val obj = raw.strictObject(TOP_KEYS)
        val unit = obj.string("unit", required = true)!!.also { if (it !in UNITS) throw Malformed() }
        val currencyCode = obj.string("currencyCode")
        val perUnit = obj.number("perUnit")
        val base = obj.optObject("base", BASE_KEYS)?.let { b ->
            PricingV2Rates(input = b.nullableNumber("inputPerMToken"), output = b.nullableNumber("outputPerMToken"))
        }
        val cache = obj.optObject("cache", CACHE_KEYS)
        var write5m: Double? = null
        var write1h: Double? = null
        cache?.optArray("writes")?.forEach { el ->
            val w = el.strictObject(WRITE_KEYS)
            val price = w.number("perMToken", required = true)
            when (w.string("ttl", required = true)) {
                "5m" -> write5m = price
                "1h" -> write1h = price
                else -> throw Malformed()
            }
        }
        val mergedBase = base?.copy(
            cacheRead = cache?.number("readPerMToken"),
            cacheWrite5m = write5m,
            cacheWrite1h = write1h,
        )
        val tiers = obj.optArray("contextTiers")?.map { el ->
            val t = el.strictObject(TIER_KEYS)
            val above = t.number("aboveInputTokens", required = true)!!
                .takeIf { it == Math.floor(it) && it >= 0 && it <= Long.MAX_VALUE.toDouble() }
                ?.toLong() ?: throw Malformed()
            val incremental = when (t.string("semantics", required = true)) {
                "whole_request" -> false
                "incremental" -> true
                else -> throw Malformed()
            }
            val write = t.number("cacheWritePerMToken")
            PricingV2Tier(
                aboveInputTokens = above,
                incremental = incremental,
                rates = PricingV2Rates(
                    input = t.number("inputPerMToken"),
                    output = t.number("outputPerMToken"),
                    cacheRead = t.number("cacheReadPerMToken"),
                    cacheWrite5m = write,
                    cacheWrite1h = write,
                ),
            )
        }.orEmpty()
        val windows = obj.optArray("timeWindows")?.map { el ->
            val w = el.strictObject(WINDOW_KEYS)
            val days = w.optArray("days")?.map { d ->
                val name = ((d as? JsonPrimitive)?.takeIf { it.isString } ?: throw Malformed()).content
                DAYS[name] ?: throw Malformed()
            }?.toSet()
            w.string("holidayCalendar")?.let { if (it !in HOLIDAY_CALENDARS) throw Malformed() }
            PricingV2Window(
                timezone = w.string("timezone", required = true)!!.also { if (it.isEmpty()) throw Malformed() },
                days = days,
                startMinute = clockMinute(w.string("start", required = true)!!, START_PATTERN),
                endMinute = clockMinute(w.string("end", required = true)!!, END_PATTERN),
                multiplier = w.number("multiplier"),
                rates = PricingV2Rates(
                    input = w.number("inputPerMToken"),
                    output = w.number("outputPerMToken"),
                    cacheRead = w.number("cacheReadPerMToken"),
                ),
            )
        }.orEmpty()
        // regionSurcharges do not take part in estimation, but the shape must still be valid
        obj.optArray("regionSurcharges")?.forEach { el ->
            val r = el.strictObject(REGION_KEYS)
            if (r.string("regionScope", required = true)!!.isEmpty()) throw Malformed()
            r.number("multiplier", required = true)
        }
        return PricingV2(
            currencyCode = currencyCode,
            unit = unit,
            base = mergedBase,
            contextTiers = tiers,
            timeWindows = windows,
            perUnit = perUnit,
        )
    }

    /** "HH:MM" -> minute of day; only end may be 24:00 (= 1440). */
    private fun clockMinute(text: String, pattern: Regex): Int {
        if (!pattern.matches(text)) throw Malformed()
        val (hour, minute) = text.split(":").map { it.toInt() }
        return hour * 60 + minute
    }

    /** An object with no unknown keys. */
    private fun JsonElement.strictObject(allowed: Set<String>): JsonObject {
        val obj = this as? JsonObject ?: throw Malformed()
        if (!allowed.containsAll(obj.keys)) throw Malformed()
        return obj
    }

    private fun JsonObject.optObject(key: String, allowed: Set<String>): JsonObject? = this[key]?.strictObject(allowed)

    private fun JsonObject.optArray(key: String): JsonArray? =
        this[key]?.let { it as? JsonArray ?: throw Malformed() }

    /** A string in the schema: the key may be absent (unless required), but when present it must be a string (null is also a violation). */
    private fun JsonObject.string(key: String, required: Boolean = false): String? {
        val el = this[key] ?: if (required) throw Malformed() else return null
        return (el as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw Malformed()
    }

    /** A number in the schema: may be negative; when present it must be a finite number (null is also a violation). */
    private fun JsonObject.number(key: String, required: Boolean = false): Double? {
        val el = this[key] ?: if (required) throw Malformed() else return null
        return numberValue(el)
    }

    /** A ["number","null"] in the schema: explicit null counts as not provided. */
    private fun JsonObject.nullableNumber(key: String): Double? {
        val el = this[key] ?: return null
        if (el is JsonNull) return null
        return numberValue(el)
    }

    private fun numberValue(el: JsonElement): Double {
        val primitive = el as? JsonPrimitive ?: throw Malformed()
        if (primitive is JsonNull || primitive.isString) throw Malformed()
        return primitive.content.toDoubleOrNull()?.takeIf { it.isFinite() } ?: throw Malformed()
    }
}
