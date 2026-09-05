package ai.oriveo.community.core.provider

import org.junit.Assert.assertEquals
import org.junit.Test

class ModelPricingFormatterTest {

    @Test
    fun `formatPerMillion - returns blank when pricing missing`() {
        assertEquals("", ModelPricingFormatter.formatPerMillion(null, null))
    }

    @Test
    fun `formatPerMillion - returns blank for zero pricing`() {
        assertEquals("", ModelPricingFormatter.formatPerMillion(0.0, 0.0))
    }

    @Test
    fun `formatPerMillion - formats standard price tier`() {
        assertEquals("$2/M", ModelPricingFormatter.formatPerMillion(0.000002, 0.000008))
    }

    @Test
    fun `formatPerMillion - falls back to completion price`() {
        assertEquals("$5/M", ModelPricingFormatter.formatPerMillion(null, 0.000005))
    }

    @Test
    fun `formatPerMillion - formats tiny price tier`() {
        assertEquals("$0.001/M", ModelPricingFormatter.formatPerMillion(0.000000001, null))
    }

    @Test
    fun `formatPerMillionValue - formats individual and zero prices`() {
        assertEquals("$0/M", ModelPricingFormatter.formatPerMillionValue(0.0))
        assertEquals("$3.75/M", ModelPricingFormatter.formatPerMillionValue(0.00000375))
        assertEquals(null, ModelPricingFormatter.formatPerMillionValue(-0.1))
    }
}
