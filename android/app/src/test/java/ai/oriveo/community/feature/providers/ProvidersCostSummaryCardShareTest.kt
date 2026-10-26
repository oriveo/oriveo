package ai.oriveo.community.feature.providers

import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.usage.CostPart
import ai.oriveo.community.core.usage.CostParts
import ai.oriveo.community.core.usage.MonthlyCostProviderEntry
import ai.oriveo.community.core.usage.MonthlyCostSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Cost summary card shares and segmented bar: shares are computed over USD only, a row with only non-USD cost shows no share, and "0%" never appears. */
class ProvidersCostSummaryCardShareTest {

    private val usdRow = entry("p-usd", CostPart("USD", 1.0))
    private val mixedRow = entry("p-mixed", CostPart("USD", 3.0), CostPart("CNY", 2.0))
    private val cnyRow = entry("p-cny", CostPart("CNY", 3.5))

    @Test
    fun share_denominator_is_usd_total_only() {
        val summary = summary(usdRow, mixedRow, cnyRow)
        assertEquals(4.0, summary.totalCost, 1e-9)
        assertEquals("25%", formatProviderShare(usdRow.cost, summary.totalCost))
        assertEquals("75%", formatProviderShare(mixedRow.cost, summary.totalCost))
    }

    @Test
    fun non_usd_only_row_has_no_share() {
        val summary = summary(usdRow, cnyRow)
        assertNull(formatProviderShare(cnyRow.cost, summary.totalCost))
    }

    @Test
    fun bar_hidden_when_no_usd_cost() {
        assertFalse(shouldShowSegmentedCostBar(summary(cnyRow, entry("p-eur", CostPart("EUR", 2.0)))))
        assertNull(formatProviderShare(cnyRow.cost, 0.0))
    }

    @Test
    fun bar_shown_with_usd_rows_and_single_row_still_hidden() {
        assertTrue(shouldShowSegmentedCostBar(summary(usdRow, cnyRow)))
        assertFalse(shouldShowSegmentedCostBar(summary(usdRow)))
    }

    private fun entry(id: String, vararg costs: CostPart) = MonthlyCostProviderEntry(
        providerKind = ProviderKind.OpenAI,
        providerID = id,
        displayName = id,
        cost = CostParts.usdAmount(costs.toList()),
        costs = costs.toList(),
    )

    private fun summary(vararg rows: MonthlyCostProviderEntry) = MonthlyCostSummary(
        totalCost = rows.sumOf { it.cost },
        totals = CostParts.split(rows.flatMap { row -> row.costs.map { it.currencyCode to it.amount } }),
        providers = rows.toList(),
    )
}
