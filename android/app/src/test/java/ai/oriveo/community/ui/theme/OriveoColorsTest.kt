package ai.oriveo.community.ui.theme

import androidx.compose.ui.graphics.Color
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

    // Memory page tokens have the same values on all three platforms; compare with iOS Palette.memoryHue.* / backgroundGrouped / warningLine / memoryAtlasDot
    @Test
    fun `memory page tokens match iOS values`() {
        val light = LightOriveoColors
        val dark = DarkOriveoColors
        assertEquals(Color(0xFFF4F4F6), light.backgroundGrouped)
        assertEquals(Color(0xFF0F1218), dark.backgroundGrouped)
        assertEquals(Color(0x66F59E0B), light.warningLine)
        assertEquals(Color(0x52FCD34D), dark.warningLine)
        assertEquals(Color(0x1A18181B), light.memoryAtlasDot)
        assertEquals(Color(0x14FFFFFF), dark.memoryAtlasDot)
        assertEquals(
            listOf(Color(0xFF4F46E5), Color(0xFF0D9488), Color(0xFFEA580C), Color(0xFF0891B2), Color(0xFF7C3AED)),
            with(light) { listOf(memoryHueAbout, memoryHuePreferences, memoryHueInstructions, memoryHueWorkingOn, memoryHueEpisodic) },
        )
        assertEquals(
            listOf(Color(0xFF818CF8), Color(0xFF2DD4BF), Color(0xFFFB923C), Color(0xFF22D3EE), Color(0xFFA78BFA)),
            with(dark) { listOf(memoryHueAbout, memoryHuePreferences, memoryHueInstructions, memoryHueWorkingOn, memoryHueEpisodic) },
        )
    }
}
