package ai.oriveo.community.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class OriveoColorsTest {

    @Test
    fun `LightOriveoColors is created successfully`() {
        assertNotNull(LightOriveoColors)
        assertNotNull(LightOriveoColors.primary)
        assertNotNull(LightOriveoColors.background)
        assertNotNull(LightOriveoColors.textPrimary)
    }

    @Test
    fun `DarkOriveoColors is created successfully`() {
        assertNotNull(DarkOriveoColors)
        assertNotNull(DarkOriveoColors.primary)
        assertNotNull(DarkOriveoColors.background)
        assertNotNull(DarkOriveoColors.textPrimary)
    }

    @Test
    fun `light and dark have different primary`() {
        // They should differ because light=0x8C5FF8 dark=0xC4B5FD
        assert(LightOriveoColors.primary != DarkOriveoColors.primary)
    }

    @Test
    fun `light and dark have different background`() {
        assert(LightOriveoColors.background != DarkOriveoColors.background)
    }

    @Test
    fun `error aliases danger in light`() {
        assertEquals(LightOriveoColors.danger, LightOriveoColors.error)
        assertEquals(LightOriveoColors.dangerSoft, LightOriveoColors.errorSoft)
    }

    @Test
    fun `error aliases danger in dark`() {
        assertEquals(DarkOriveoColors.danger, DarkOriveoColors.error)
        assertEquals(DarkOriveoColors.dangerSoft, DarkOriveoColors.errorSoft)
    }

    @Test
    fun `all 6 capability colors are distinct in light`() {
        val caps = setOf(
            LightOriveoColors.capReasoning,
            LightOriveoColors.capText,
            LightOriveoColors.capImage,
            LightOriveoColors.capFile,
            LightOriveoColors.capWeb,
            LightOriveoColors.capImageGen,
        )
        assertEquals(6, caps.size)
    }

    @Test
    fun `all new surface variants exist`() {
        assertNotNull(LightOriveoColors.backgroundBase)
        assertNotNull(LightOriveoColors.backgroundSecondary)
        assertNotNull(LightOriveoColors.surfaceElevated)
        assertNotNull(LightOriveoColors.surfaceInset)
        assertNotNull(LightOriveoColors.surfaceChrome)
    }

    @Test
    fun `shadow colors exist`() {
        assertNotNull(LightOriveoColors.shadow)
        assertNotNull(LightOriveoColors.shadowStrong)
        assertNotNull(LightOriveoColors.tabBar)
    }

    @Test
    fun `capability background colors exist`() {
        assertNotNull(LightOriveoColors.capReasoningBg)
        assertNotNull(LightOriveoColors.capTextBg)
        assertNotNull(LightOriveoColors.capImageBg)
        assertNotNull(LightOriveoColors.capFileBg)
        assertNotNull(LightOriveoColors.capWebBg)
        assertNotNull(LightOriveoColors.capImageGenBg)
    }

    @Test
    fun `capability border colors exist`() {
        assertNotNull(LightOriveoColors.capReasoningBorder)
        assertNotNull(LightOriveoColors.capTextBorder)
        assertNotNull(LightOriveoColors.capImageBorder)
        assertNotNull(LightOriveoColors.capFileBorder)
        assertNotNull(LightOriveoColors.capWebBorder)
        assertNotNull(LightOriveoColors.capImageGenBorder)
    }
}
