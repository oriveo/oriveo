package ai.oriveo.community.core.util

import org.junit.Assert.assertEquals
import org.junit.Test

class MemoryBudgetsTest {

    @Test
    fun `backup budget uses one quarter of heap`() {
        assertEquals(64L * 1024L * 1024L, backupMemoryBudgetBytes(256L * 1024L * 1024L))
    }

    @Test
    fun `backup budget is bounded for very small and large heaps`() {
        assertEquals(16L * 1024L * 1024L, backupMemoryBudgetBytes(32L * 1024L * 1024L))
        assertEquals(256L * 1024L * 1024L, backupMemoryBudgetBytes(2L * 1024L * 1024L * 1024L))
    }
}
