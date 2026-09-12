package ai.oriveo.community.ui.component

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The floating glass tab bar follows the geometry measured on the iOS 26 system tab bar (1pt = 1dp):
 * a 62-high capsule with 8 of padding at each end plus 86 per item (274 for three items); a 94×53 lens
 * centered on the item, sitting 4 from the capsule end for the edge tabs.
 */
class LiquidGlassTabBarLayoutMetricsTest {

    @Test
    fun `bar hugs its content like the iOS 26 tab bar`() {
        assertEquals(62.dp, LiquidGlassTabBarMetrics.barHeight)
        assertEquals(274.dp, LiquidGlassTabBarMetrics.barWidth(itemCount = 3))
        // A single tab still keeps the end padding instead of collapsing to zero width
        assertEquals(102.dp, LiquidGlassTabBarMetrics.barWidth(itemCount = 1))
        assertEquals(102.dp, LiquidGlassTabBarMetrics.barWidth(itemCount = 0))
    }

    @Test
    fun `lens is wider than an item and concentric with the capsule ends`() {
        val lensHalf = LiquidGlassTabBarMetrics.lensWidth / 2
        val firstCenter = liquidGlassItemCenterX(0)
        val lastCenter = liquidGlassItemCenterX(2)

        assertEquals(51.dp, firstCenter)
        assertEquals(223.dp, lastCenter)
        // The edge tab's lens sits 4 from the capsule end and is concentric with it: half capsule height 31 − half lens height 26.5 = 4.5 ≈ 4 on each side
        assertEquals(4.dp, firstCenter - lensHalf)
        assertEquals(4.dp, LiquidGlassTabBarMetrics.barWidth(3) - (lastCenter + lensHalf))
        assertTrue(LiquidGlassTabBarMetrics.lensWidth > LiquidGlassTabBarMetrics.itemWidth)
        assertTrue(LiquidGlassTabBarMetrics.lensHeight < LiquidGlassTabBarMetrics.barHeight)
    }

    @Test
    fun `pointer x maps to the item under the finger and clamps at both ends`() {
        assertEquals(0, liquidGlassIndexAt(xDp = 0f, itemCount = 3))
        assertEquals(0, liquidGlassIndexAt(xDp = 93f, itemCount = 3))
        assertEquals(1, liquidGlassIndexAt(xDp = 95f, itemCount = 3))
        assertEquals(1, liquidGlassIndexAt(xDp = 179f, itemCount = 3))
        assertEquals(2, liquidGlassIndexAt(xDp = 181f, itemCount = 3))
        assertEquals(2, liquidGlassIndexAt(xDp = 500f, itemCount = 3))
        assertEquals(0, liquidGlassIndexAt(xDp = -40f, itemCount = 3))
        assertEquals(0, liquidGlassIndexAt(xDp = 120f, itemCount = 1))
    }

    @Test
    fun `lifted lens grows about 8dp on every side`() {
        val liftedWidth = LiquidGlassTabBarMetrics.lensWidth.value * LiquidGlassTabBarMetrics.LIFT_SCALE_X
        val liftedHeight = LiquidGlassTabBarMetrics.lensHeight.value * LiquidGlassTabBarMetrics.LIFT_SCALE_Y

        assertEquals(110f, liftedWidth, 0.01f)
        assertEquals(69f, liftedHeight, 0.01f)
    }
}
