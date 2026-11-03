package ai.oriveo.community.ui.component

import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.core.usage.CostPart
import java.time.Instant
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Monthly cost on a provider list row: compaction only applies to the USD part; non-USD parts keep the platform currency format verbatim. */
class ProviderListCardCostTextTest {

    @Test
    fun `pt-BR non-USD part keeps ICU text while USD part is compacted`() {
        val ptBr = Locale.forLanguageTag("pt-BR")
        val cny = CostPart("CNY", 1234.5)
        val icu = CostFormatter.formatPart(cny, ptBr)
        // In pt-BR `.` is the thousands separator and `,` the decimal point: trimming trailing zeros after `.` would cut 1.234,50 to 1.234
        assertTrue(icu, icu.contains("1.234,50"))

        val text = CostFormatter.formatParts(
            listOf(CostPart("USD", 1.5), cny),
            ptBr,
            usdPartTransform = { compactCurrencyText(it, ptBr) },
        )

        assertEquals("${CostFormatter.usd(1.5, 1, 1, ptBr)} + $icu", text)
    }

    @Test
    fun compact_en_keeps_symbol_prefix() {
        assertEquals("$12.5", compactCurrencyText(CostFormatter.usd(12.5, 2, 2, Locale.US), Locale.US))
        assertEquals("$1,234.5", compactCurrencyText("$1,234.50", Locale.US))
        assertEquals("$0", usdTextOrZero("", Locale.US))
    }

    @Test
    fun compact_de() {
        val de = Locale.GERMANY
        val full = CostFormatter.usd(12.5, 2, 2, de)
        assertTrue(full, full.contains("12,50") && full.endsWith("$"))

        val compact = compactCurrencyText(full, de)

        assertEquals(CostFormatter.usd(12.5, 1, 1, de), compact)
        assertTrue(compact, compact.contains("12,5") && !compact.contains("12,50") && compact.endsWith("$"))
    }

    @Test
    fun compact_ar() {
        val ar = Locale.forLanguageTag("ar")
        val full = CostFormatter.usd(12.5, 2, 2, ar)

        val compact = compactCurrencyText(full, ar)

        assertEquals(CostFormatter.usd(12.5, 1, 1, ar), compact)
        assertTrue(compact, compact.contains("$") && compact.contains("12"))
    }

    @Test
    fun zero_fallback_de() {
        val text = usdTextOrZero("", Locale.GERMANY)
        assertEquals("0 $", text.replace('\u00A0', ' ').replace('\u202F', ' '))
        assertEquals("1,2 $", usdTextOrZero("1,2 $", Locale.GERMANY))
    }

    @Test
    fun provider_balance_half_rounds_away() {
        val balance = ProviderBalance(currency = "USD", total = 0.125, fetchedAt = Instant.EPOCH)
        assertEquals("$0.13", formatProviderBalanceAmount(balance, Locale.US))
    }

    @Test
    fun `cached currency formats stay per locale and digits`() {
        val zh = Locale.forLanguageTag("zh-Hans")
        val ptBr = Locale.forLanguageTag("pt-BR")
        val first = CostFormatter.formatPart(CostPart("CNY", 3.62), zh)
        assertEquals(first, CostFormatter.formatPart(CostPart("CNY", 3.62), zh))
        assertTrue(CostFormatter.formatPart(CostPart("CNY", 3.62), ptBr).contains("3,62"))
        assertTrue(CostFormatter.formatPart(CostPart("CNY", 0.0039), zh).contains("0.0039"))
    }
}
