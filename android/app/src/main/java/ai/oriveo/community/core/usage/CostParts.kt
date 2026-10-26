package ai.oriveo.community.core.usage

import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.NonUsdCost
import ai.oriveo.community.core.provider.CostSource

/** Cost total for one currency: the amount is the currency's own value, with no conversion. */
data class CostPart(
    val currencyCode: String,
    val amount: Double,
)

/**
 * Accumulates costs per currency, never across currencies.
 *
 * - An empty currency means USD; currency codes are upper-cased.
 * - Amounts of the same currency add up, never across currencies.
 * - USD comes first, the rest by ascending code; a currency whose total is <= [CostFormatter.COST_EPSILON] is left out.
 */
object CostParts {
    const val USD = "USD"

    fun normalizeCode(code: String?): String =
        code?.trim()?.uppercase()?.takeIf { it.isNotEmpty() } ?: USD

    fun isUsd(code: String?): Boolean = normalizeCode(code) == USD

    /**
     * The billed parts of one message: estimatedCost is always the USD part; nonUsdCost is the only non-USD part,
     * and a non-USD part whose source is UNKNOWN is not counted. A mixed-currency message counts toward both the USD and its own currency total.
     */
    fun messageAmounts(estimatedCost: Double, nonUsdCost: NonUsdCost?): List<Pair<String, Double>> = buildList {
        add(USD to estimatedCost)
        if (nonUsdCost != null && nonUsdCost.costSource != CostSource.UNKNOWN.name) {
            add(normalizeCode(nonUsdCost.currencyCode) to nonUsdCost.amount)
        }
    }

    fun split(amounts: Iterable<Pair<String?, Double>>): List<CostPart> {
        val sums = linkedMapOf<String, Double>()
        amounts.forEach { (code, amount) ->
            // Only finite positive amounts count: negative values and NaN stay out of the totals.
            if (!(amount.isFinite() && amount > 0.0)) return@forEach
            val key = normalizeCode(code)
            sums[key] = (sums[key] ?: 0.0) + amount
        }
        return sums
            .filter { (_, amount) -> amount > CostFormatter.COST_EPSILON }
            .map { (code, amount) -> CostPart(currencyCode = code, amount = amount) }
            .sortedWith(compareBy<CostPart> { it.currencyCode != USD }.thenBy { it.currencyCode })
    }

    /** Per-currency parts of one message for display: USD first, zero amounts left out, and a non-USD part with source UNKNOWN is not included. */
    fun messageParts(estimatedCost: Double, nonUsdCost: NonUsdCost?): List<CostPart> =
        split(messageAmounts(estimatedCost, nonUsdCost))

    /** Non-USD currencies of one message whose amount is unknown (source UNKNOWN; shown as unavailable, never as 0). */
    fun messageNotAvailableCodes(nonUsdCost: NonUsdCost?): List<String> =
        nonUsdCost?.takeIf { it.costSource == CostSource.UNKNOWN.name }
            ?.let { listOf(normalizeCode(it.currencyCode)) }
            .orEmpty()

    /** Per-currency parts for a conversation: estimatedCost is the USD total, nonUsdCostTotals the totals of the other currencies. */
    fun conversationParts(estimatedCost: Double, nonUsdCostTotals: Map<String, Double>): List<CostPart> =
        split(listOf(USD to estimatedCost) + nonUsdCostTotals.map { (code, amount) -> code to amount })

    /** The USD amount; 0 when there is no USD part (budgets and Server usage count USD only). */
    fun usdAmount(parts: List<CostPart>): Double = parts.firstOrNull { it.currencyCode == USD }?.amount ?: 0.0
}
