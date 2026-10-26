@file:Suppress("PropertyName")

package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextBudgetLimit
import ai.oriveo.community.core.context.ContextCompactNumber
import ai.oriveo.community.core.context.ContextWindowInput
import kotlin.math.abs
import kotlin.math.roundToLong

/** Picker selection; [FOLLOW] means the conversation has no cap of its own and uses the global default. */
enum class ContextCapSelection(val wire: String) {
    FOLLOW("follow"),
    AUTO("auto"),
    UNLIMITED("unlimited"),
    CUSTOM("custom"),
}

/** Input budget of one cap option: B and what bounds it; both null for an unknown window without a custom cap. */
data class ContextCapOptionBudget(val B: Int?, val limitedBy: ContextBudgetLimit?)

enum class ContextCapHintKind(val wire: String) {
    NONE("none"),
    OVER("over"),
    AT("at"),
    UNDER("under"),
}

/** Custom start compared with the price line; [gap] is set only for [ContextCapHintKind.UNDER]. */
data class ContextCapCustomHint(val kind: ContextCapHintKind, val gap: Int?)

/** Per-conversation cap picker state (contract P9·U7 rule 1). */
data class ContextCapPicker(
    val selected: ContextCapSelection,
    val effective: ContextCapOptionBudget,
    val auto: ContextCapOptionBudget,
    val unlimited: ContextCapOptionBudget,
    val ticks: List<Int>,
    val customStart: Int,
    val sliderIndex: Int,
    val priceLineTickIndex: Int?,
    val unlimitedCrossesPriceLine: Boolean,
    val customHint: ContextCapCustomHint,
)

/** Result of committing a typed custom number (contract P9·U7 rule 2). */
data class ContextCapCommit(val value: Int, val adjusted: Boolean, val restored: Boolean)

/** Per-million-token prices; long = the long-context tier above the price line. */
data class ContextCapPricing(
    val basePrompt: Double?,
    val baseCompletion: Double?,
    val longPrompt: Double?,
    val longCompletion: Double?,
)

enum class ContextCapWindowLine(val wire: String) {
    UNKNOWN("unknown"),
    WINDOW("window"),
    WINDOW_PRICE_LINE("windowPriceLine"),
    ABOVE_LINE("aboveLine"),
}

/** Long-context multipliers in tenths (20 = x2.0); a side is null unless it is above x1.0. */
data class ContextCapMultiplier(val inputTenths: Int?, val outputTenths: Int?) {
    /** Both sides listed and equal: the "both" sentence. */
    val isBoth: Boolean get() = inputTenths != null && inputTenths == outputTenths
}

/** Context panel cap row and window row (contract P9·U7 rule 3). */
data class ContextCapPanel(
    /** null = unknown window with auto / unlimited: show the option name instead. */
    val capValue: Int?,
    val limitedByModel: Boolean,
    val actual: Int?,
    val windowLine: ContextCapWindowLine,
    val priceLineDistance: Int?,
    val multiplier: ContextCapMultiplier?,
)

enum class ContextCapSettingsSelection(val wire: String) {
    AUTO("auto"),
    UNLIMITED("unlimited"),
    CUSTOM("custom"),
}

/** Settings › Context default cap group (contract P9·U7 rule 4). */
data class ContextCapSettings(val selected: ContextCapSettingsSelection, val customPrefill: Int)

/** Localized templates of the panel window row and multiplier sentences (%n$s placeholders). */
class ContextCapPanelStrings(
    /** %1$s window. */
    val windowLine: String,
    /** %1$s window, %2$s price line, %3$s multiplier sentence. */
    val windowLinePrice: String,
    /** %1$s window, %2$s price line. */
    val windowLinePricePlain: String,
    /** %1$s price line. */
    val aboveLine: String,
    /** %1$s shared multiplier. */
    val multBoth: String,
    /** %1$s input multiplier. */
    val multInput: String,
    /** %1$s output multiplier. */
    val multOutput: String,
    /** %1$s input, %2$s output multiplier. */
    val multSplit: String,
) {
    /** Templates looked up by resource key name. */
    constructor(byKey: (String) -> String) : this(
        windowLine = byKey("context_cap_window_line"),
        windowLinePrice = byKey("context_cap_window_line_price"),
        windowLinePricePlain = byKey("context_cap_window_line_price_plain"),
        aboveLine = byKey("context_cap_above_line"),
        multBoth = byKey("context_cap_mult_both"),
        multInput = byKey("context_cap_mult_input"),
        multOutput = byKey("context_cap_mult_output"),
        multSplit = byKey("context_cap_mult_split"),
    )
}

/** Pure presentation for the cap picker, typed-number commit, context panel and settings default cap. */
object ContextCapPresentation {
    /** Custom start when nothing gives a B (unknown window without a custom cap). */
    const val CUSTOM_START_FALLBACK: Int = 128_000

    /** Over this many digits (leading zeros not counted) the typed number saturates to Int.MAX_VALUE and is always adjusted. */
    private const val MAX_DIGITS: Int = 10

    /**
     * Unicode White_Space plus the grouping marks , . ' U+2019 _ are ignored when reading a typed number.
     * White_Space is spelled out as code points: the Java-only IsWhite_Space property class does not compile on the Android 8 ICU
     * regex engine (minSdk 26) and the failure kills this object's initializer.
     */
    private val IGNORED = Regex(
        "[\\u0009-\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000,.'\\u2019_]",
    )
    private val ASCII_DIGITS = Regex("^[0-9]+$")

    // Unicode first-strong isolate / pop directional isolate around numbers mixed into text.
    private const val FSI = "\u2068"
    private const val PDI = "\u2069"

    fun picker(
        window: ContextWindowInput,
        conversationCap: ContextBudgetCap?,
        globalCap: ContextBudgetCap,
    ): ContextCapPicker {
        val effectiveBudget = ContextBudget.window(window.copy(budgetCap = conversationCap ?: globalCap))
        val effective = ContextCapOptionBudget(effectiveBudget.B, effectiveBudget.limitedBy)
        val auto = option(window, ContextBudgetCap.Auto)
        val unlimited = option(window, ContextBudgetCap.Unlimited)
        val u = effectiveBudget.U
        val t = window.priceLineTokens
        val ticks = ContextBudget.capTicks(u, t)
        val customStart = if (conversationCap is ContextBudgetCap.Custom) {
            option(window, conversationCap).B ?: CUSTOM_START_FALLBACK
        } else {
            effective.B ?: CUSTOM_START_FALLBACK
        }
        return ContextCapPicker(
            selected = when (conversationCap) {
                null -> ContextCapSelection.FOLLOW
                ContextBudgetCap.Auto -> ContextCapSelection.AUTO
                ContextBudgetCap.Unlimited -> ContextCapSelection.UNLIMITED
                is ContextBudgetCap.Custom -> ContextCapSelection.CUSTOM
            },
            effective = effective,
            auto = auto,
            unlimited = unlimited,
            ticks = ticks,
            customStart = customStart,
            sliderIndex = nearestTickIndex(ticks, customStart),
            priceLineTickIndex = t?.let { ticks.indexOf(it) }?.takeIf { it >= 0 },
            unlimitedCrossesPriceLine = u != null && t != null && u > t,
            customHint = customHint(customStart, t),
        )
    }

    /** Index of the tick nearest to [value]; on a tie the lower tick wins. */
    fun nearestTickIndex(ticks: List<Int>, value: Int): Int =
        ticks.indices.minByOrNull { abs(ticks[it].toLong() - value.toLong()) } ?: 0

    private fun customHint(customStart: Int, t: Int?): ContextCapCustomHint = when {
        t == null -> ContextCapCustomHint(ContextCapHintKind.NONE, null)
        customStart > t -> ContextCapCustomHint(ContextCapHintKind.OVER, null)
        customStart == t -> ContextCapCustomHint(ContextCapHintKind.AT, null)
        else -> ContextCapCustomHint(ContextCapHintKind.UNDER, t - customStart)
    }

    private fun option(window: ContextWindowInput, cap: ContextBudgetCap): ContextCapOptionBudget {
        val budget = ContextBudget.window(window.copy(budgetCap = cap))
        return ContextCapOptionBudget(budget.B, budget.limitedBy)
    }

    /** Typed digits with whitespace and grouping marks removed; null when not a non-empty ASCII digit run. */
    fun typedDigits(text: String): String? =
        text.replace(IGNORED, "").takeIf { ASCII_DIGITS.matches(it) }

    /** Typed number before clamping (over 10 significant digits reads as Int.MAX_VALUE); null when unreadable. */
    fun typedValue(text: String): Long? {
        val digits = typedDigits(text) ?: return null
        return if (saturates(digits)) Int.MAX_VALUE.toLong() else digits.toLong()
    }

    /** Leading zeros do not count toward the digit limit ("00000000064000" is 64000). */
    private fun saturates(digits: String): Boolean = digits.trimStart('0').length > MAX_DIGITS

    /** Input echo: the clamped value a commit would store; null when the text is unreadable. */
    fun echoValue(text: String, u: Int?): Int? =
        commit(text, u, previous = 0).takeUnless { it.restored }?.value

    /**
     * Commits a typed custom number: unreadable text restores [previous]; otherwise
     * clamp(n, CUSTOM_CAP_MIN, U ?? Int.MAX_VALUE), adjusted when the value moved or n had over 10 digits.
     */
    fun commit(text: String, u: Int?, previous: Int): ContextCapCommit {
        val digits = typedDigits(text) ?: return ContextCapCommit(previous, adjusted = false, restored = true)
        val saturated = saturates(digits)
        val n = typedValue(digits)!!
        val upper = (u ?: Int.MAX_VALUE).toLong()
        // U below CUSTOM_CAP_MIN leaves U as the only reachable value
        val value = minOf(maxOf(n, ContextBudget.CUSTOM_CAP_MIN.toLong()), upper)
        return ContextCapCommit(value.toInt(), adjusted = saturated || value != n, restored = false)
    }

    fun panel(
        window: ContextWindowInput,
        conversationCap: ContextBudgetCap?,
        globalCap: ContextBudgetCap,
        used: Int,
        pricing: ContextCapPricing?,
    ): ContextCapPanel {
        val cap = conversationCap ?: globalCap
        val budget = ContextBudget.window(window.copy(budgetCap = cap))
        val u = budget.U
        val b = budget.B
        val t = window.priceLineTokens
        val limitedByModel = cap is ContextBudgetCap.Custom && u != null && cap.tokens > u
        val windowLine = when {
            u == null -> ContextCapWindowLine.UNKNOWN
            t == null -> ContextCapWindowLine.WINDOW
            b == null || t >= b -> ContextCapWindowLine.WINDOW_PRICE_LINE
            else -> ContextCapWindowLine.ABOVE_LINE
        }
        return ContextCapPanel(
            capValue = b,
            limitedByModel = limitedByModel,
            actual = if (limitedByModel) b else null,
            windowLine = windowLine,
            priceLineDistance = if (windowLine == ContextCapWindowLine.ABOVE_LINE && t != null) maxOf(t - used, 0) else null,
            multiplier = pricing?.let(::multiplier),
        )
    }

    /** Long-context multipliers; null when neither side is above x1.0. */
    fun multiplier(pricing: ContextCapPricing): ContextCapMultiplier? {
        val input = tenths(pricing.basePrompt, pricing.longPrompt)
        val output = tenths(pricing.baseCompletion, pricing.longCompletion)
        if (input == null && output == null) return null
        return ContextCapMultiplier(input, output)
    }

    private fun tenths(base: Double?, long: Double?): Int? {
        if (base == null || base <= 0.0 || long == null) return null
        val value = (long / base * 10.0).roundToLong()
        return if (value > 10) value.toInt() else null
    }

    /** Settings default cap from the stored value; anything unparseable (null) reads as auto. */
    fun settings(stored: ContextBudgetCap?): ContextCapSettings = when (stored) {
        ContextBudgetCap.Unlimited -> ContextCapSettings(ContextCapSettingsSelection.UNLIMITED, ContextBudget.AUTO_CAP_DEFAULT)
        is ContextBudgetCap.Custom -> ContextCapSettings(ContextCapSettingsSelection.CUSTOM, stored.tokens)
        ContextBudgetCap.Auto, null -> ContextCapSettings(ContextCapSettingsSelection.AUTO, ContextBudget.AUTO_CAP_DEFAULT)
    }

    /** Compact token count wrapped in FSI…PDI so it reads correctly inside any-direction text. */
    fun isolatedCompact(tokens: Long, locale: String): String =
        FSI + ContextCompactNumber.format(tokens, locale) + PDI

    /** Cap label: the option name for auto / unlimited, the isolated compact number for custom. */
    fun capLabel(cap: ContextBudgetCap, autoLabel: String, unlimitedLabel: String, locale: String): String = when (cap) {
        ContextBudgetCap.Auto -> autoLabel
        ContextBudgetCap.Unlimited -> unlimitedLabel
        is ContextBudgetCap.Custom -> isolatedCompact(cap.tokens.toLong(), locale)
    }

    /** Multiplier number from tenths (20 -> "2", 15 -> "1.5") with the language's compact-table decimal mark. */
    fun multiplierNumber(tenths: Int, locale: String): String {
        val whole = tenths / 10
        val frac = tenths % 10
        if (frac == 0) return whole.toString()
        val decimal = ContextCompactNumber.TABLE.getValue(ContextCompactNumber.resolveLocale(locale)).decimal
        return "$whole$decimal$frac"
    }

    /** Multiplier sentence: "both" when equal, otherwise the listed side(s). */
    fun multiplierText(multiplier: ContextCapMultiplier, strings: ContextCapPanelStrings, locale: String): String {
        val input = multiplier.inputTenths?.let { multiplierNumber(it, locale) }
        val output = multiplier.outputTenths?.let { multiplierNumber(it, locale) }
        return when {
            multiplier.isBoth -> String.format(strings.multBoth, input)
            input != null && output != null -> String.format(strings.multSplit, input, output)
            input != null -> String.format(strings.multInput, input)
            else -> String.format(strings.multOutput, output)
        }
    }

    /**
     * Panel window row: model window, with the price line when T >= B, or the above-the-line row when T < B;
     * null when the window is unknown (no row).
     */
    fun windowLineText(
        panel: ContextCapPanel,
        window: ContextWindowInput,
        strings: ContextCapPanelStrings,
        locale: String,
    ): String? {
        val w = window.W?.let { isolatedCompact(it.toLong(), locale) }
        val line = window.priceLineTokens?.let { isolatedCompact(it.toLong(), locale) }
        return when (panel.windowLine) {
            ContextCapWindowLine.UNKNOWN -> null
            ContextCapWindowLine.WINDOW -> w?.let { String.format(strings.windowLine, it) }
            ContextCapWindowLine.WINDOW_PRICE_LINE -> {
                if (w == null || line == null) return null
                val multiplier = panel.multiplier
                if (multiplier == null) {
                    String.format(strings.windowLinePricePlain, w, line)
                } else {
                    String.format(strings.windowLinePrice, w, line, multiplierText(multiplier, strings, locale))
                }
            }
            ContextCapWindowLine.ABOVE_LINE -> line?.let { String.format(strings.aboveLine, it) }
        }
    }

    /** Cap row value: the isolated B, or the option name when the window is unknown (auto / unlimited). */
    fun capRowValue(
        panel: ContextCapPanel,
        cap: ContextBudgetCap,
        autoLabel: String,
        unlimitedLabel: String,
        locale: String,
    ): String = panel.capValue?.let { isolatedCompact(it.toLong(), locale) }
        ?: capLabel(cap, autoLabel, unlimitedLabel, locale)

    /** Settings root Context row value "{cap} · {mode}" from the localized [template] (%1$s cap, %2$s mode). */
    fun settingsRowValue(
        template: String,
        cap: ContextBudgetCap,
        mode: String,
        autoLabel: String,
        unlimitedLabel: String,
        locale: String,
    ): String = String.format(template, capLabel(cap, autoLabel, unlimitedLabel, locale), mode)
}
