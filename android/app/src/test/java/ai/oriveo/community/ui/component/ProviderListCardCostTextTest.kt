package ai.oriveo.community.ui.component

import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.usage.CostPart
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
            usdPartTransform = ::compactCurrencyText,
        )

        assertEquals("$1.5 + $icu", text)
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
