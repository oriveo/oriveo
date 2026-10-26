package ai.oriveo.community.core.model

import ai.oriveo.community.core.usage.CostPart
import ai.oriveo.community.core.usage.CostParts
import java.math.RoundingMode
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale
import java.util.Optional
import java.util.concurrent.ConcurrentHashMap

/**
 * Cost formatting shared by every client.
 *
 *   <= COST_EPSILON -> not shown ("")
 *   < 0.0001        -> "$0.000XX" (5 decimals)
 *   < 0.01          -> "$0.XXXX" (4 decimals)
 *   >= 0.01         -> "$X.XX" (2 decimals)
 *
 * Per-currency parts: the USD part keeps the `$` form above; a non-USD part uses the platform currency format
 * (UI locale, standard symbol), with decimals chosen by the same tiers from that part's own amount; parts are joined with ` + `.
 */
object CostFormatter {

    const val COST_EPSILON = 0.00001

    private const val PART_SEPARATOR = " + "

    /** USD precision tiers: the number of decimals chosen by amount. */
    fun fractionDigits(value: Double): Int = when {
        value < 0.0001 -> 5
        value < 0.01 -> 4
        else -> 2
    }

    fun format(value: Double): String {
        if (!value.isFinite() || value <= COST_EPSILON) return ""
        return "${"$"}%.${fractionDigits(value)}f".format(Locale.US, value)
    }

    /** One currency part: USD goes through [format]; other currencies use the currency format and standard symbol of [locale], with no conversion. */
    fun formatPart(part: CostPart, locale: Locale): String {
        val code = CostParts.normalizeCode(part.currencyCode)
        if (code == CostParts.USD) return format(part.amount)
        val amount = part.amount
        if (!amount.isFinite() || amount <= COST_EPSILON) return ""
        val digits = fractionDigits(amount)
        val format = currencyFormat(locale, code, digits)
            ?: return "$code ${"%.${digits}f".format(locale, amount)}"
        // NumberFormat is not thread-safe: cached instances are locked per instance while formatting
        return synchronized(format) { format.format(amount) }
    }

    /** NumberFormat is expensive to construct: cached by (locale, currency, digits) so every list row reuses the same instance. */
    private val currencyFormats = ConcurrentHashMap<Triple<Locale, String, Int>, Optional<NumberFormat>>()

    private fun currencyFormat(locale: Locale, code: String, digits: Int): NumberFormat? =
        currencyFormats.getOrPut(Triple(locale, code, digits)) {
            val currency = runCatching { Currency.getInstance(code) }.getOrNull()
            Optional.ofNullable(
                currency?.let {
                    NumberFormat.getCurrencyInstance(locale).apply {
                        this.currency = it
                        minimumFractionDigits = digits
                        maximumFractionDigits = digits
                        roundingMode = RoundingMode.HALF_UP
                    }
                },
            )
        }.orElse(null)

    /**
     * Per-currency cost text: each part is rendered by [formatPart] and joined with ` + `; every currency in [notAvailableCodes]
     * whose amount is unknown shows the caller's existing "not available" text [notAvailableText] (never 0). [usdPartTransform] applies only to the USD part
     * (the `$` form is fixed, so compacting is safe); non-USD parts keep the platform currency format verbatim (grouping / decimal separators vary by locale).
     * Returns "" when no part can be shown.
     */
    fun formatParts(
        parts: List<CostPart>,
        locale: Locale,
        notAvailableCodes: List<String> = emptyList(),
        notAvailableText: String = "",
        usdPartTransform: (String) -> String = { it },
    ): String {
        val amounts = parts.mapNotNull { part ->
            val text = formatPart(part, locale).takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            if (CostParts.normalizeCode(part.currencyCode) == CostParts.USD) usdPartTransform(text) else text
        }
        val unavailable = if (notAvailableText.isEmpty()) emptyList() else notAvailableCodes.map { notAvailableText }
        return (amounts + unavailable).joinToString(PART_SEPARATOR)
    }
}
