package ai.oriveo.community.ui.component.markdown

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LatexRenderingBudgetTest {

    @Test
    fun `accepts normal formula bitmap`() {
        assertTrue(isLatexBitmapWithinBudget(width = 1_200, height = 300))
    }

    @Test
    fun `rejects excessive pixel allocation`() {
        assertFalse(isLatexBitmapWithinBudget(width = 4_096, height = 4_096))
    }

    @Test
    fun `rejects excessive single dimension`() {
        assertFalse(isLatexBitmapWithinBudget(width = 4_097, height = 1))
    }
}
