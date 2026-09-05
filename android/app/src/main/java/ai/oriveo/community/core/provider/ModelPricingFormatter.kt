package ai.oriveo.community.core.provider

import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

object ModelPricingFormatter {
    fun formatPerMillionValue(perTokenPrice: Double): String? {
        if (perTokenPrice < 0.0) return null

        val pricePerMillion = perTokenPrice * 1_000_000
        if (pricePerMillion == 0.0) return "$0/M"

        val pattern = if (pricePerMillion < 0.01) "0.########" else "0.###"
        val formatter = DecimalFormat(pattern, DecimalFormatSymbols(Locale.US))
        return "$${formatter.format(pricePerMillion)}/M"
    }

    fun formatPerMillion(
        promptPrice: Double?,
        completionPrice: Double?,
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
        return formatPerMillionValue(pricePerMillion / 1_000_000).orEmpty()
    }
}
