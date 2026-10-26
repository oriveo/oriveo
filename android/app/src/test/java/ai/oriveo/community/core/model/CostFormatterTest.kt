package ai.oriveo.community.core.model

import ai.oriveo.community.core.usage.CostPart
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

class CostFormatterTest {

    // ── COST_EPSILON ─────────────────────────────────────────────

    @Test
    fun `COST_EPSILON is 0_00001`() {
        assertEquals(0.00001, CostFormatter.COST_EPSILON, 0.0)
    }

    // ── format ───────────────────────────────────────────────────

    @Test
    fun `format returns empty string for zero`() {
        assertEquals("", CostFormatter.format(0.0))
    }

    @Test
    fun `format returns empty string for negative value`() {
        assertEquals("", CostFormatter.format(-1.0))
    }

    @Test
    fun `format returns empty string for NaN`() {
        assertEquals("", CostFormatter.format(Double.NaN))
    }

    @Test
    fun `format returns empty string for Infinity`() {
        assertEquals("", CostFormatter.format(Double.POSITIVE_INFINITY))
    }

    @Test
    fun `format returns empty string at epsilon boundary`() {
        assertEquals("", CostFormatter.format(CostFormatter.COST_EPSILON))
    }

    @Test
    fun `format returns actual amount for very small values`() {
        assertEquals("$0.00002", CostFormatter.format(0.00002))
        assertEquals("$0.00009", CostFormatter.format(0.00009))
    }

    @Test
    fun `format returns 4 decimal places for small values`() {
        assertEquals("$0.0023", CostFormatter.format(0.0023))
        assertEquals("$0.0001", CostFormatter.format(0.0001))
    }

    @Test
    fun `format returns 2 decimal places for normal values`() {
        assertEquals("$1.50", CostFormatter.format(1.50))
        assertEquals("$0.05", CostFormatter.format(0.05))
    }

    @Test
    fun `format returns 2 decimal places at boundary 0_01`() {
        assertEquals("$0.01", CostFormatter.format(0.01))
    }

    @Test
    fun `format handles large value`() {
        assertEquals("$99.99", CostFormatter.format(99.99))
    }

    // ── per-currency parts ────────────────────────────────

    @Test
    fun `non-USD part uses its own digit tier`() {
        assertEquals("¥0.00002", CostFormatter.formatPart(CostPart("CNY", 0.00002), Locale.forLanguageTag("zh-Hans")))
        assertEquals("¥0.0039", CostFormatter.formatPart(CostPart("CNY", 0.0039), Locale.forLanguageTag("zh-Hans")))
        assertEquals("€2.00", CostFormatter.formatPart(CostPart("EUR", 2.0), Locale.US))
    }

    @Test
    fun `USD part keeps dollar rendering regardless of locale`() {
        assertEquals("$1.20", CostFormatter.formatPart(CostPart("usd", 1.2), Locale.GERMANY))
    }

    @Test
    fun `parts joined with plus and not available text appended`() {
        val text = CostFormatter.formatParts(
            parts = listOf(CostPart("USD", 0.25)),
            locale = Locale.US,
            notAvailableCodes = listOf("CNY"),
            notAvailableText = "Not available",
        )
        assertEquals("$0.25 + Not available", text)
    }

    @Test
    fun `no parts yields empty text`() {
        assertEquals("", CostFormatter.formatParts(emptyList(), Locale.US))
    }

    @Test
    fun `usd part transform leaves non-USD ICU text untouched`() {
        val text = CostFormatter.formatParts(
            parts = listOf(CostPart("USD", 1.5), CostPart("CNY", 3.5)),
            locale = Locale.forLanguageTag("zh-Hans"),
            usdPartTransform = { it.trimEnd('0') },
        )
        assertEquals("$1.5 + ¥3.50", text)
    }
}
