package ai.oriveo.community.ui.component

import android.content.res.Resources
import android.util.TypedValue
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BrandImageBitmapCacheTest {

    @Test
    fun `missing density split resource is reported unresolvable instead of throwing`() {
        
        
        
        val resources = mockk<Resources>()
        every { resources.getValue(any<Int>(), any(), any()) } throws
            Resources.NotFoundException("Resource ID #0x7f000000")

        assertFalse(canResolveResource(resources, resId = 0x7f000000))
    }

    @Test
    fun `resolvable resource is reported available`() {
        val resources = mockk<Resources>()
        every { resources.getValue(any<Int>(), any<TypedValue>(), any()) } returns Unit

        assertTrue(canResolveResource(resources, resId = 0x7f000000))
    }

    @Test
    fun `sample size keeps decoded edge at or above requested edge`() {
        assertEquals(4, calculateResourceSampleSize(sourceEdgePx = 540, targetEdgePx = 114))
        assertEquals(2, calculateResourceSampleSize(sourceEdgePx = 540, targetEdgePx = 168))
        assertEquals(1, calculateResourceSampleSize(sourceEdgePx = 540, targetEdgePx = 300))
    }

    @Test
    fun `large hero requests keep the original bitmap`() {
        assertEquals(1, calculateResourceSampleSize(sourceEdgePx = 540, targetEdgePx = 600))
        assertEquals(1, calculateResourceSampleSize(sourceEdgePx = 540, targetEdgePx = 540))
    }

    @Test
    fun `invalid dimensions fall back to an undecimated decode`() {
        assertEquals(1, calculateResourceSampleSize(sourceEdgePx = 0, targetEdgePx = 120))
        assertEquals(1, calculateResourceSampleSize(sourceEdgePx = 540, targetEdgePx = 0))
    }
}
