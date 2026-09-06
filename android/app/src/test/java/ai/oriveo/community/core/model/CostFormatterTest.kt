package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

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

    @Test
    fun `parse handles formatted string with tilde`() {
        assertEquals(1.50, CostFormatter.parse("~$1.50"), 0.001)
    }

    @Test
    fun `parse handles plain number`() {
        assertEquals(0.0023, CostFormatter.parse("0.0023"), 0.00001)
    }

    @Test
    fun `parse returns 0 for invalid string`() {
        assertEquals(0.0, CostFormatter.parse("abc"), 0.001)
    }

    @Test
    fun `parse returns 0 for empty string`() {
        assertEquals(0.0, CostFormatter.parse(""), 0.001)
    }

    @Test
    fun `parse strips tilde and dollar sign`() {
        assertEquals(5.0, CostFormatter.parse("~$5.00"), 0.001)
    }

    @Test
    fun `parse handles less than format with tilde`() {
        assertEquals(0.0001, CostFormatter.parse("~<$0.0001"), 0.00001)
    }

    @Test
    fun `parse handles new format without tilde`() {
        assertEquals(1.50, CostFormatter.parse("$1.50"), 0.001)
        assertEquals(0.0001, CostFormatter.parse("<$0.0001"), 0.00001)
    }

    // ── round-trip ───────────────────────────────────────────────

    @Test
    fun `format then parse round-trips correctly`() {
        val original = 1.50
        val formatted = CostFormatter.format(original)
        val parsed = CostFormatter.parse(formatted)
        assertEquals(original, parsed, 0.01)
    }
}
