package ai.oriveo.community.ui.component

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LiquidGlassTabBarLayoutMetricsTest {

    @Test
    fun `compact metrics keep the shell tighter than regular`() {
        val compact = liquidGlassTabBarLayoutMetrics(isCompact = true)
        val regular = liquidGlassTabBarLayoutMetrics(isCompact = false)

        assertEquals(58.dp, compact.barHeight)
        assertEquals(62.dp, regular.barHeight)
        assertEquals(288.dp, compact.maxBarWidth)
        assertEquals(300.dp, regular.maxBarWidth)
        assertEquals(9.dp, compact.outerHorizontalInset)
        assertEquals(10.dp, regular.outerHorizontalInset)
        assertEquals(23.dp, compact.iconSize)
        assertEquals(25.dp, regular.iconSize)
        
        assertTrue(compact.iconSize < regular.iconSize)
        
        assertTrue(compact.capsuleWidthFraction >= 0.85f)
        assertTrue(regular.capsuleWidthFraction >= 0.85f)
        
        assertTrue(compact.barHeight < regular.barHeight)
        assertTrue(compact.maxBarWidth < regular.maxBarWidth)
        
        assertEquals(1.5.dp, compact.labelTopSpacing)
        assertEquals(2.dp, regular.labelTopSpacing)
        assertTrue(compact.labelTopSpacing > 0.dp)
        
        assertTrue(compact.outerVerticalInset <= 3.dp)
        assertTrue(regular.outerVerticalInset <= 3.5.dp)
    }

    @Test
    fun `capsule is clearly narrower than each segment`() {
        val metrics = liquidGlassTabBarLayoutMetrics(isCompact = false)
        val bounds = resolveLiquidGlassCapsuleBounds(
            totalWidth = metrics.maxBarWidth,
            itemCount = 3,
            selectedIndex = 1,
            metrics = metrics,
        )
        val segmentWidth = (metrics.maxBarWidth - metrics.outerHorizontalInset * 2) / 3f

        assertEquals(segmentWidth * metrics.capsuleWidthFraction, bounds.width)
        
        assertTrue(bounds.width < segmentWidth * 0.95f)
        assertTrue(bounds.width > segmentWidth * 0.8f)
    }

    @Test
    fun `capsule for first and last tab stays inside the shell breathing room`() {
        val metrics = liquidGlassTabBarLayoutMetrics(isCompact = false)
        val first = resolveLiquidGlassCapsuleBounds(
            totalWidth = metrics.maxBarWidth,
            itemCount = 3,
            selectedIndex = 0,
            metrics = metrics,
        )
        val last = resolveLiquidGlassCapsuleBounds(
            totalWidth = metrics.maxBarWidth,
            itemCount = 3,
            selectedIndex = 2,
            metrics = metrics,
        )

        assertTrue(first.left > metrics.outerHorizontalInset)
        assertTrue(last.right < metrics.maxBarWidth - metrics.outerHorizontalInset)
    }
}
