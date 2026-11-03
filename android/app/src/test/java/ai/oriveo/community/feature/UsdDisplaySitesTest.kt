package ai.oriveo.community.feature

import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.usage.CostPart
import ai.oriveo.community.feature.chat.ContextCompactionCost
import ai.oriveo.community.feature.chat.compactionCostText
import ai.oriveo.community.feature.chat.formatCompactionCost
import ai.oriveo.community.feature.providers.detail.formatAmount
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

/** USD display sites on the usage and provider balance screens follow CostFormatter.usd. */
class UsdDisplaySitesTest {

    private val de = Locale.GERMANY

    private fun normalize(text: String): String = text.replace(' ', ' ').replace(' ', ' ')

    @Test
    fun provider_balance_usd_de() {
        assertEquals("1.234,50 $", normalize(formatAmount(1234.5, "USD", de)))
        assertEquals("$1,234.50", formatAmount(1234.5, "usd", Locale.US))
    }

    @Test
    fun provider_balance_cny_platform() {
        val expected = CostFormatter.formatPart(CostPart(currencyCode = "CNY", amount = 12.5), de)
        assertEquals(expected, formatAmount(12.5, "CNY", de))
        assertEquals("12,50 CN¥", normalize(formatAmount(12.5, "CNY", de)))
    }

    @Test
    fun provider_detail_balance_half_rounds_away() {
        assertEquals("$0.13", formatAmount(0.125, "USD", Locale.US))
        assertEquals("CN¥0.13", formatAmount(0.125, "CNY", Locale.US))
    }

    @Test
    fun compaction_cost_uses_cost_tiers() {
        assertEquals("$0.00002", formatCompactionCost(0.00002, Locale.US))
        assertEquals("$0.0013", formatCompactionCost(0.00125, Locale.US))
        assertEquals("$0.01", formatCompactionCost(0.0123, Locale.US))
        assertEquals("$0.13", formatCompactionCost(0.125, Locale.US))
        assertEquals(
            "$0.00002",
            compactionCostText(ContextCompactionCost.Amount(0.00002), Locale.US, NO_EXTRA, UNAVAILABLE),
        )
    }

    @Test
    fun compaction_zero_cost_shows_unavailable() {
        listOf(0.0, 1e-5, -0.5).forEach { value ->
            assertEquals("", formatCompactionCost(value, Locale.US))
            assertEquals(
                "value=$value",
                UNAVAILABLE,
                compactionCostText(ContextCompactionCost.Amount(value), Locale.US, NO_EXTRA, UNAVAILABLE),
            )
        }
        assertEquals(UNAVAILABLE, compactionCostText(ContextCompactionCost.Unavailable, Locale.US, NO_EXTRA, UNAVAILABLE))
        assertEquals(NO_EXTRA, compactionCostText(ContextCompactionCost.NoExtraCost, Locale.US, NO_EXTRA, UNAVAILABLE))
    }

    private companion object {
        const val NO_EXTRA = "no-extra-cost"
        const val UNAVAILABLE = "cost-unavailable"
    }
}
