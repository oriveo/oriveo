package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.unit.Constraints
import ai.oriveo.community.ui.component.MAX_HEIGHT_CONSTRAINT_PX
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for the streaming-height floor recurrence, mirroring the iOS
 * AssistantStreamingHeightFloorTests suite: verifies that it only grows, never shrinks --
 * when a block closes and gets re-parsed shorter, the floor clamps to the peak so
 * contentSize doesn't dip and jitter the stick-to-bottom follow behavior.
 */
class StreamingHeightFloorTest {

    @Test
    fun `floor grows with measured height`() {
        var floor = 0
        floor = nextStreamingHeightFloor(floor, 100)
        assertEquals(100, floor)
        floor = nextStreamingHeightFloor(floor, 150)
        assertEquals(150, floor)
        floor = nextStreamingHeightFloor(floor, 220)
        assertEquals(220, floor)
    }

    @Test
    fun `floor holds when measured shrinks (does not rebound after a block closes)`() {
        var floor = 0
        floor = nextStreamingHeightFloor(floor, 150)
        // a code block/table closing triggers a re-parse that momentarily measures 120: the floor clamps and stays at 150 (no rebound).
        floor = nextStreamingHeightFloor(floor, 120)
        assertEquals(150, floor)
        // once new content pushes past the previous peak, the floor rises along with it.
        floor = nextStreamingHeightFloor(floor, 180)
        assertEquals(180, floor)
    }

    @Test
    fun `equal measured keeps floor unchanged`() {
        assertEquals(150, nextStreamingHeightFloor(150, 150))
    }

    /**
     * The floor gets fed back into `heightIn(min=)`; if it exceeds what [Constraints] can
     * represent, every subsequent frame crashes. The assertion goes straight through a real
     * [Constraints] construction rather than re-deriving the bit-width math.
     */
    @Test
    fun `floor never exceeds what Constraints can represent`() {
        val floor = nextStreamingHeightFloor(0, 262_146)
        assertEquals(MAX_HEIGHT_CONSTRAINT_PX, floor)
        Constraints(minWidth = 0, maxWidth = Constraints.Infinity, minHeight = floor)
    }

    @Test
    fun `clamped floor stays clamped across further growth`() {
        var floor = nextStreamingHeightFloor(0, Int.MAX_VALUE)
        assertEquals(MAX_HEIGHT_CONSTRAINT_PX, floor)
        floor = nextStreamingHeightFloor(floor, Int.MAX_VALUE)
        assertEquals(MAX_HEIGHT_CONSTRAINT_PX, floor)
        Constraints(minWidth = 0, maxWidth = Constraints.Infinity, minHeight = floor)
    }
}
