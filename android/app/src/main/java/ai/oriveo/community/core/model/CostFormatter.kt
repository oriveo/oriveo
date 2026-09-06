package ai.oriveo.community.core.model

import java.util.Locale

object CostFormatter {

    const val COST_EPSILON = 0.00001

    fun format(value: Double): String {
        if (!value.isFinite() || value <= COST_EPSILON) return ""
        return when {
            value < 0.0001 -> "${"$"}%.5f".format(Locale.US, value)
            value < 0.01 -> "${"$"}%.4f".format(Locale.US, value)
            else -> "${"$"}%.2f".format(Locale.US, value)
        }
    }

    fun parse(text: String): Double {
        val cleaned = text
            .replace("~", "")
            .replace("<", "")
            .replace("$", "")
            .trim()
        return cleaned.toDoubleOrNull() ?: 0.0
    }
}
