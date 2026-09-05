package ai.oriveo.community.ui.component

import androidx.compose.ui.unit.Constraints
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A regression test for the domain of a height floor fed back into layout constraints.
 *
 * The production crash was `SizeNode.getTargetConstraints` throwing "Can't represent a width of
 * 0 and height of 262146 in Constraints": `Modifier.heightIn(min=)` leaves the width unset, so
 * widthVal=0 takes 13 bits, leaving only 18 bits for height. This constructs a real
 * [Constraints] instance directly rather than reproducing the bit-width math, letting Compose
 * itself answer whether it can actually be constructed after clamping.
 */
class HeightConstraintLimitsTest {

    /** The exact value from the crash: proves this is a genuinely unrepresentable input, not a guess. */
    private val crashingHeightPx = 262_146

    @Test
    fun `raw crash height is genuinely unrepresentable`() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            Constraints(minWidth = 0, maxWidth = Constraints.Infinity, minHeight = crashingHeightPx)
        }
        assertTrue(
            error.message.orEmpty().contains("Can't represent a width of 0 and height of $crashingHeightPx"),
        )
    }

    @Test
    fun `clamped height is representable with an unconstrained width axis`() {
        val clamped = coerceHeightConstraintPx(crashingHeightPx)
        assertEquals(MAX_HEIGHT_CONSTRAINT_PX, clamped)
        // Passes by not throwing: the heightIn(min=) shape (no value on the width axis, only a height floor).
        Constraints(minWidth = 0, maxWidth = Constraints.Infinity, minHeight = clamped)
        // The height() shape (matching min and max) must also hold.
        Constraints(minWidth = 0, maxWidth = Constraints.Infinity, minHeight = clamped, maxHeight = clamped)
    }

    @Test
    fun `clamped height stays representable under a fixed width (fillMaxWidth outside)`() {
        val clamped = coerceHeightConstraintPx(Int.MAX_VALUE)
        // The production chain is fillMaxWidth -> heightIn: SizeNode's enforceIncoming
        // intersects with the fixed width from the outer modifier.
        listOf(1, 1_220, 4_096, 8_190).forEach { widthPx ->
            Constraints(minWidth = widthPx, maxWidth = widthPx, minHeight = clamped)
        }
    }

    @Test
    fun `normal heights pass through untouched`() {
        assertEquals(0, coerceHeightConstraintPx(0))
        assertEquals(1, coerceHeightConstraintPx(1))
        assertEquals(2_712, coerceHeightConstraintPx(2_712))
        assertEquals(MAX_HEIGHT_CONSTRAINT_PX, coerceHeightConstraintPx(MAX_HEIGHT_CONSTRAINT_PX))
    }

    @Test
    fun `non-positive measurements collapse to zero`() {
        assertEquals(0, coerceHeightConstraintPx(-1))
        assertEquals(0, coerceHeightConstraintPx(Int.MIN_VALUE))
    }
}
