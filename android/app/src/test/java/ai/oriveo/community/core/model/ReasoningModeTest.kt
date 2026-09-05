package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReasoningModeTest {

    @Test
    fun `titleResId returns correct values for all modes`() {
        assertEquals(ai.oriveo.community.R.string.reasoning_auto, ReasoningMode.Automatic.titleResId)
        assertEquals(ai.oriveo.community.R.string.reasoning_fast, ReasoningMode.Fast.titleResId)
        assertEquals(ai.oriveo.community.R.string.reasoning_balanced, ReasoningMode.Balanced.titleResId)
        assertEquals(ai.oriveo.community.R.string.reasoning_deep, ReasoningMode.Deep.titleResId)
        assertEquals(ai.oriveo.community.R.string.reasoning_max, ReasoningMode.Max.titleResId)
    }

    @Test
    fun `titleResId covers all enum values`() {
        ReasoningMode.entries.forEach { mode ->
            assertTrue("titleResId should be positive for $mode", mode.titleResId > 0)
        }
    }

    @Test
    fun `all 5 modes exist`() {
        assertEquals(5, ReasoningMode.entries.size)
    }
}
