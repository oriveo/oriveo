package ai.oriveo.community.feature.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExpensiveModelHintTest {

    @Test
    fun `ratio above threshold returns multiplier`() {
        assertEquals(7, evaluateExpensiveModelMultiplier(0.001, 0.007))
    }

    @Test
    fun `ratio just above threshold returns 5`() {
        assertEquals(5, evaluateExpensiveModelMultiplier(0.001, 0.0051))
    }

    @Test
    fun `ratio equals threshold returns null`() {
        assertNull(evaluateExpensiveModelMultiplier(0.001, 0.005))
    }

    @Test
    fun `ratio below threshold returns null`() {
        assertNull(evaluateExpensiveModelMultiplier(0.001, 0.003))
    }

    @Test
    fun `old price null returns null`() {
        assertNull(evaluateExpensiveModelMultiplier(null, 0.007))
    }

    @Test
    fun `new price null returns null`() {
        assertNull(evaluateExpensiveModelMultiplier(0.001, null))
    }

    @Test
    fun `old price zero returns null`() {
        assertNull(evaluateExpensiveModelMultiplier(0.0, 0.007))
    }

    @Test
    fun `reverse switch cheaper model returns null`() {
        assertNull(evaluateExpensiveModelMultiplier(0.007, 0.001))
    }
}
