package ai.oriveo.community.core.provider

import java.math.RoundingMode
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale
import java.util.Optional
import java.util.concurrent.ConcurrentHashMap

object ModelPricingFormatter {
    fun formatPerMillionValue(perTokenPrice: Double): String? {
        if (perTokenPrice < 0.0) return null

        val pricePerMillion = perTokenPrice * 1_000_000
        if (pricePerMillion == 0.0) return "$0/M"

        val pattern = if (pricePerMillion < 0.01) "0.########" else "0.###"
        val formatter = DecimalFormat(pattern, DecimalFormatSymbols(Locale.US))
        return "$${formatter.format(pricePerMillion)}/M"
    }

    /**
     * Per-million-token unit price in the selected currency: USD keeps the notation and precision of [formatPerMillionValue];
     * other currencies use the platform currency format ([locale], standard symbol) with the same decimal places as USD, no conversion.
     */
    fun formatPerMillionValue(perTokenPrice: Double, currencyCode: String, locale: Locale): String? {
        val code = currencyCode.trim().uppercase()
        if (code.isEmpty() || code == DeliveredCostResolver.USD) return formatPerMillionValue(perTokenPrice)
        if (perTokenPrice < 0.0) return null

        val pricePerMillion = perTokenPrice * 1_000_000
        val maxDigits = if (pricePerMillion != 0.0 && pricePerMillion < 0.01) 8 else 3
        val format = currencyFormat(locale, code, maxDigits)
            ?: return "$code ${DecimalFormat(if (maxDigits == 8) "0.########" else "0.###", DecimalFormatSymbols(locale)).format(pricePerMillion)}/M"
        // NumberFormat is not thread safe: cached instances are locked per instance while formatting
        return synchronized(format) { format.format(pricePerMillion) } + "/M"
    }

    fun formatPerMillion(
        promptPrice: Double?,
        completionPrice: Double?,
    ): String = formatPerMillion(promptPrice, completionPrice, DeliveredCostResolver.USD, Locale.US)

    fun formatPerMillion(
        promptPrice: Double?,
        completionPrice: Double?,
        currencyCode: String,
        locale: Locale,
    ): String {
        if (promptPrice == null && completionPrice == null) {
            return ""
        }

        val prompt = promptPrice ?: 0.0
        val completion = completionPrice ?: 0.0

        if (prompt == 0.0 && completion == 0.0) {
            return ""
        }

        val pricePerMillion = (if (prompt > 0.0) prompt else completion) * 1_000_000
        if (pricePerMillion == 0.0) {
            return ""
        }
        return formatPerMillionValue(pricePerMillion / 1_000_000, currencyCode, locale).orEmpty()
    }

    /** NumberFormat is expensive to construct: cached per (locale, currency, max digits) and reused for every list row. */
    private val currencyFormats = ConcurrentHashMap<Triple<Locale, String, Int>, Optional<NumberFormat>>()

    private fun currencyFormat(locale: Locale, code: String, maxDigits: Int): NumberFormat? =
        currencyFormats.getOrPut(Triple(locale, code, maxDigits)) {
            val currency = runCatching { Currency.getInstance(code) }.getOrNull()
            Optional.ofNullable(
                currency?.let {
                    NumberFormat.getCurrencyInstance(locale).apply {
                        this.currency = it
                        minimumFractionDigits = 0
                        maximumFractionDigits = maxDigits
                        // Same rounding as the USD DecimalFormat (HALF_EVEN), so the same amount gets the same digits and last digit in both currencies.
                        roundingMode = RoundingMode.HALF_EVEN
                    }
                },
            )
        }.orElse(null)
}
