@file:Suppress("PropertyName", "LocalVariableName")

package ai.oriveo.community.core.context

import kotlin.math.ceil
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Window semantics: `total` shares W between input and output; `inputOnly` reserves nothing. */
enum class ContextWindowKind(val wire: String) {
    TOTAL("total"),
    INPUT_ONLY("inputOnly");

    companion object {
        fun fromWire(wire: String): ContextWindowKind =
            entries.firstOrNull { it.wire == wire } ?: throw IllegalArgumentException("unknown windowKind $wire")
    }
}

/** User-selectable input budget cap: auto (default), unlimited, or a custom token count. */
sealed interface ContextBudgetCap {
    /** Wire value: "auto" / "unlimited" strings, or the custom token count as an integer. */
    val wire: Any

    data object Auto : ContextBudgetCap {
        override val wire: Any get() = "auto"
    }

    data object Unlimited : ContextBudgetCap {
        override val wire: Any get() = "unlimited"
    }

    data class Custom(val tokens: Int) : ContextBudgetCap {
        override val wire: Any get() = tokens
    }

    companion object {
        val DEFAULT: ContextBudgetCap = Auto

        /** Named (non-custom) options in fixture order. */
        val OPTIONS: List<ContextBudgetCap> = listOf(Auto, Unlimited)

        /**
         * Parses a raw JSON value; returns null when rejected. Accepts only the exact strings
         * "auto" / "unlimited" and integers in [CUSTOM_CAP_MIN, CUSTOM_CAP_MAX], including floating
         * values that are exactly integral (e.g. 64000.0); booleans, null, fractional numbers,
         * numeric strings and legacy keys like "64k" are rejected.
         */
        fun parse(raw: Any?): ContextBudgetCap? = when (raw) {
            "auto" -> Auto
            "unlimited" -> Unlimited
            is Int -> customOrNull(raw.toLong())
            is Long -> customOrNull(raw)
            is Double -> integralOrNull(raw)
            is Float -> integralOrNull(raw.toDouble())
            else -> null
        }

        private fun integralOrNull(value: Double): ContextBudgetCap? =
            if (value.isFinite() && value == Math.floor(value) &&
                value >= ContextBudget.CUSTOM_CAP_MIN && value <= ContextBudget.CUSTOM_CAP_MAX
            ) {
                Custom(value.toInt())
            } else {
                null
            }

        private fun customOrNull(tokens: Long): ContextBudgetCap? =
            if (tokens in ContextBudget.CUSTOM_CAP_MIN.toLong()..ContextBudget.CUSTOM_CAP_MAX.toLong()) {
                Custom(tokens.toInt())
            } else {
                null
            }
    }
}

/** What bound the input budget B; ties resolve custom over window, priceLine over autoDefault over window. */
enum class ContextBudgetLimit(val wire: String) {
    CUSTOM("custom"),
    PRICE_LINE("priceLine"),
    AUTO_DEFAULT("autoDefault"),
    WINDOW("window"),
}

/** Where the input size estimate comes from. */
@Serializable
enum class ContextBasis(val wire: String) {
    @SerialName("observed") OBSERVED("observed"),
    @SerialName("estimated") ESTIMATED("estimated"),
    @SerialName("unknown") UNKNOWN("unknown");

    companion object {
        fun fromWire(wire: String): ContextBasis =
            entries.firstOrNull { it.wire == wire } ?: throw IllegalArgumentException("unknown basis $wire")
    }
}

/** Output limit sources in priority order: user setting, recipe, model. */
data class ContextMaxOutput(
    val user: Int? = null,
    val recipe: Int? = null,
    val model: Int? = null,
)

data class ContextWindowInput(
    val W: Int?,
    val windowKind: ContextWindowKind,
    val maxOutput: ContextMaxOutput,
    val budgetCap: ContextBudgetCap = ContextBudgetCap.DEFAULT,
    /** Provider price line (tokens); only bounds `auto` when >= PRICE_LINE_CAP_MIN. */
    val priceLineTokens: Int? = null,
)

data class ContextDerivedBudget(
    val preCompactAt: Int,
    val sendCompactAt: Int,
    val compactTargetMax: Int,
    val reminderAt: Int,
    val tail: Int,
    val userMessagesMax: Int,
    val summaryMax: Int,
    val systemMax: Int,
    val recallMax: Int,
)

/**
 * Window budget; unknown windows leave R/U null. With auto / unlimited they also leave B/derived
 * null and turn proactive compaction off; a custom cap still yields B and derived thresholds.
 */
data class ContextWindowBudget(
    val known: Boolean,
    val W: Int?,
    val O: Int,
    val R: Int?,
    val U: Int?,
    val B: Int?,
    /** Null exactly when B is null. */
    val limitedBy: ContextBudgetLimit?,
    val oWire: Int,
    val derived: ContextDerivedBudget?,
    val proactiveCompaction: Boolean,
)

data class PHatInput(
    val observedPrevious: Int?,
    val estDynamicPrevious: Int,
    val estAnswerPrevious: Int,
    val estNewMessages: List<Int>,
    val estDynamicNow: Int,
    val compactedSincePrevious: Boolean,
    val estimatedFull: Int,
)

data class PHatResult(val pHat: Int, val basis: ContextBasis)

enum class ContextDisplayKind(val wire: String) {
    PERCENT("percent"),
    UNAVAILABLE("unavailable"),
}

enum class ContextDisplayTone(val wire: String) {
    NEUTRAL("neutral"),
    WARM("warm"),
    ERROR("error"),
}

data class ContextDisplayInput(
    val windowKnown: Boolean,
    val pHat: Int,
    val B: Int?,
    val basis: ContextBasis,
    val observedEver: Boolean,
    val overflowed: Boolean,
)

/** Ring display; never a 0% for an unmeasured value. `estimatedPercent` is for the detail panel only. */
data class ContextDisplay(
    val display: ContextDisplayKind,
    val percent: Int?,
    val tone: ContextDisplayTone?,
    val estimatedPercent: Int? = null,
)

/** Pure budget functions shared with iOS / Web through `budget.v1.json`. */
object ContextBudget {
    const val RHO0: Double = 0.5
    const val EWMA_ALPHA: Double = 0.3
    const val RHO_MIN: Double = 0.15
    const val RHO_MAX: Double = 0.7
    const val SAFETY_FACTOR: Double = 1.15
    const val MIN_SAMPLES: Int = 3
    const val OVERFLOW_MISS_FACTOR: Double = 1.25
    const val MESSAGE_OVERHEAD_TOKENS: Int = 4
    const val MIN_KNOWN_WINDOW: Int = 1024
    const val DEFAULT_MAX_OUTPUT: Int = 8192
    const val WARM_PERCENT: Int = 70
    const val CUSTOM_CAP_MIN: Int = 32_000
    const val CUSTOM_CAP_MAX: Int = Int.MAX_VALUE
    const val AUTO_CAP_DEFAULT: Int = 256_000
    const val PRICE_LINE_CAP_MIN: Int = 64_000
    val CAP_TICK_LADDER: List<Int> = listOf(
        32_000, 64_000, 128_000, 256_000, 384_000, 512_000, 768_000, 1_000_000, 1_500_000, 2_000_000,
    )

    fun window(input: ContextWindowInput): ContextWindowBudget {
        val o = listOf(input.maxOutput.user, input.maxOutput.recipe, input.maxOutput.model)
            .firstOrNull { it != null && it > 0 } ?: DEFAULT_MAX_OUTPUT
        val w = input.W
        if (w == null || w < MIN_KNOWN_WINDOW) {
            val cap = input.budgetCap
            if (cap is ContextBudgetCap.Custom) {
                val b = maxOf(cap.tokens, CUSTOM_CAP_MIN).toLong()
                return ContextWindowBudget(
                    known = false, W = null, O = o, R = null, U = null, B = b.toInt(),
                    limitedBy = ContextBudgetLimit.CUSTOM, oWire = o, derived = derived(b), proactiveCompaction = true,
                )
            }
            return ContextWindowBudget(
                known = false, W = null, O = o, R = null, U = null, B = null,
                limitedBy = null, oWire = o, derived = null, proactiveCompaction = false,
            )
        }
        val wl = w.toLong()
        val r: Long
        val oWire: Long
        when (input.windowKind) {
            ContextWindowKind.TOTAL -> {
                // ceil(0.10W) / floor(0.5W) in exact integer arithmetic
                r = minOf(maxOf(o.toLong(), (wl + 9) / 10), wl / 2)
                oWire = minOf(o.toLong(), r)
            }
            ContextWindowKind.INPUT_ONLY -> {
                r = 0
                oWire = o.toLong()
            }
        }
        val u = wl - r
        val (b, limitedBy) = inputBudget(u, input.budgetCap, input.priceLineTokens)
        return ContextWindowBudget(
            known = true,
            W = w,
            O = o,
            R = r.toInt(),
            U = u.toInt(),
            B = b.toInt(),
            limitedBy = limitedBy,
            oWire = oWire.toInt(),
            derived = derived(b),
            proactiveCompaction = true,
        )
    }

    /**
     * B for a known window: auto = min(U, AUTO_CAP_DEFAULT, T') with T' only when >= PRICE_LINE_CAP_MIN;
     * unlimited = U; custom = min(max(c, CUSTOM_CAP_MIN), U). Candidates are listed in tie-break order.
     */
    private fun inputBudget(u: Long, cap: ContextBudgetCap, priceLineTokens: Int?): Pair<Long, ContextBudgetLimit> {
        val candidates: List<Pair<Long, ContextBudgetLimit>> = when (cap) {
            ContextBudgetCap.Auto -> listOfNotNull(
                priceLineTokens?.takeIf { it >= PRICE_LINE_CAP_MIN }?.let { it.toLong() to ContextBudgetLimit.PRICE_LINE },
                AUTO_CAP_DEFAULT.toLong() to ContextBudgetLimit.AUTO_DEFAULT,
                u to ContextBudgetLimit.WINDOW,
            )
            ContextBudgetCap.Unlimited -> listOf(u to ContextBudgetLimit.WINDOW)
            is ContextBudgetCap.Custom -> listOf(
                maxOf(cap.tokens, CUSTOM_CAP_MIN).toLong() to ContextBudgetLimit.CUSTOM,
                u to ContextBudgetLimit.WINDOW,
            )
        }
        // minByOrNull keeps the first of equal minima, which is the tie-break winner
        return candidates.minByOrNull { it.first }!!
    }

    /**
     * Slider stops, ascending and distinct: U < CUSTOM_CAP_MIN gives [U]; otherwise
     * (ladder plus the price line when >= CUSTOM_CAP_MIN) within [CUSTOM_CAP_MIN, U], plus U.
     * Unknown U has no upper bound and adds no U stop.
     */
    fun capTicks(u: Int?, priceLineTokens: Int?): List<Int> {
        if (u != null && u < CUSTOM_CAP_MIN) return listOf(u)
        val stops = sortedSetOf<Int>()
        CAP_TICK_LADDER.forEach { stops.add(it) }
        priceLineTokens?.takeIf { it >= CUSTOM_CAP_MIN }?.let { stops.add(it) }
        val bounded = stops.filter { it >= CUSTOM_CAP_MIN && (u == null || it <= u) }.toSortedSet()
        if (u != null) bounded.add(u)
        return bounded.toList()
    }

    /** Budget-derived thresholds for an input budget B (also used by the checkpoint span and fallback). */
    fun derived(b: Long): ContextDerivedBudget = ContextDerivedBudget(
        preCompactAt = (b * 75 / 100).toInt(),
        sendCompactAt = (b * 90 / 100).toInt(),
        compactTargetMax = (b * 50 / 100).toInt(),
        reminderAt = (b * 30 / 100).toInt(),
        tail = (b * 25 / 100).coerceIn(4_000L, 48_000L).toInt(),
        userMessagesMax = minOf(16_000L, b * 10 / 100).toInt(),
        summaryMax = minOf(4_000L, maxOf(1_000L, b * 5 / 100)).toInt(),
        systemMax = minOf(b * 25 / 100, 32_000L).toInt(),
        recallMax = (b * 7 / 100).toInt(),
    )

    fun utf8Bytes(text: String): Int = text.toByteArray(Charsets.UTF_8).size

    fun estimateText(text: String, rhoHi: Double): Int = ceil(utf8Bytes(text) * rhoHi).toInt()

    fun estimateMessage(text: String, rhoHi: Double): Int = estimateText(text, rhoHi) + MESSAGE_OVERHEAD_TOKENS

    fun pHat(input: PHatInput): PHatResult {
        val observed = input.observedPrevious
        if (observed == null || input.compactedSincePrevious) {
            return PHatResult(input.estimatedFull, ContextBasis.ESTIMATED)
        }
        val p = observed - input.estDynamicPrevious + input.estAnswerPrevious +
            input.estNewMessages.sum() + input.estDynamicNow
        return PHatResult(p, ContextBasis.OBSERVED)
    }

    fun display(input: ContextDisplayInput): ContextDisplay {
        val b = input.B
        if (!input.windowKnown || b == null || b <= 0) {
            return ContextDisplay(ContextDisplayKind.UNAVAILABLE, percent = null, tone = null)
        }
        val percent = ceilPercent(input.pHat, b)
        if (!input.observedEver) {
            return ContextDisplay(ContextDisplayKind.UNAVAILABLE, percent = null, tone = null, estimatedPercent = percent)
        }
        val tone = when {
            input.overflowed -> ContextDisplayTone.ERROR
            percent >= WARM_PERCENT -> ContextDisplayTone.WARM
            else -> ContextDisplayTone.NEUTRAL
        }
        return ContextDisplay(ContextDisplayKind.PERCENT, percent = percent, tone = tone)
    }

    /** ceil(100 * pHat / B) in exact integer arithmetic. */
    private fun ceilPercent(pHat: Int, b: Int): Int {
        val num = 100L * pHat
        return Math.floorDiv(num + b - 1, b.toLong()).toInt()
    }
}
