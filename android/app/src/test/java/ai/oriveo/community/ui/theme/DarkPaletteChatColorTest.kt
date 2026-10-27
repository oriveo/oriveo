package ai.oriveo.community.ui.theme

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.feature.chat.components.chatAuroraGlowLayers
import ai.oriveo.community.feature.chat.components.sentQuoteChipContentColor
import ai.oriveo.community.feature.notes.neutralFolderChipActiveContent
import ai.oriveo.community.ui.component.markdown.MarkdownTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * No hard-coded dark colors: the chat page's brand gradient / aurora / code block border take the current palette in dark, and the light values stay unchanged.
 * dark-ocean (whose primary / accent are entirely different from the default purple) verifies that a palette switch is followed immediately.
 */
class DarkPaletteChatColorTest {

    private val ocean = DarkOceanOriveoColors

    @Test
    fun `dark user bubble gradient follows palette primary to accent`() {
        assertEquals(listOf(ocean.primary, ocean.accent), OriveoGradients.primaryStops(ocean, isDark = true))
        assertNotEquals(
            OriveoGradients.primaryStops(DarkOriveoColors, isDark = true),
            OriveoGradients.primaryStops(ocean, isDark = true),
        )
    }

    @Test
    fun `dark pressed gradient is primaryActive to accent`() {
        assertEquals(listOf(ocean.primaryActive, ocean.accent), OriveoGradients.primaryPressedStops(ocean, isDark = true))
    }

    @Test
    fun `light gradients keep original brand stops`() {
        assertEquals(
            listOf(Color(0xFF8347F5), Color(0xFF6B3BC7)),
            OriveoGradients.primaryStops(LightOriveoColors, isDark = false),
        )
        assertEquals(
            listOf(Color(0xFF7238E5), Color(0xFF5A2BB0)),
            OriveoGradients.primaryPressedStops(LightOriveoColors, isDark = false),
        )
    }

    @Test
    fun `primary button content is palette onPrimary in dark and white in light`() {
        assertEquals(ocean.onPrimary, OriveoGradients.onPrimaryContent(ocean, isDark = true))
        assertEquals(DarkOriveoColors.onPrimary, OriveoGradients.onPrimaryContent(DarkOriveoColors, isDark = true))
        assertEquals(Color.White, OriveoGradients.onPrimaryContent(LightOriveoColors, isDark = false))
    }

    @Test
    fun `quote chip inside user bubble uses bubble ink`() {
        assertEquals(ocean.onPrimary, sentQuoteChipContentColor(ocean, isDark = true))
        assertEquals(Color.White, sentQuoteChipContentColor(LightOriveoColors, isDark = false))
    }

    @Test
    fun `neutral folder chip active content is palette bg in dark and white in light`() {
        assertEquals(ocean.backgroundBase, neutralFolderChipActiveContent(ocean, isDark = true))
        assertEquals(Color.White, neutralFolderChipActiveContent(LightOriveoColors, isDark = false))
    }

    @Test
    fun `dark aurora layers follow formula times glowK`() {
        val layers = chatAuroraGlowLayers(ocean, isDark = true)
        assertEquals(4, layers.size)
        assertEquals(ocean.primary.copy(alpha = 0.26f * ocean.glowK), layers[0].color)
        assertEquals(ocean.accent.copy(alpha = 0.18f * ocean.glowK), layers[1].color)
        assertEquals(ocean.primary.copy(alpha = 0.16f * ocean.glowK), layers[2].color)
        assertEquals(ocean.accent.copy(alpha = 0.09f * ocean.glowK), layers[3].color)
    }

    @Test
    fun `default dark aurora bottom uses glowK 0_4`() {
        val bottom = chatAuroraGlowLayers(DarkOriveoColors, isDark = true).first().color
        assertEquals(DarkOriveoColors.primary.copy(alpha = 0.26f * 0.4f), bottom)
    }

    @Test
    fun `light aurora keeps original three layers`() {
        val layers = chatAuroraGlowLayers(LightOriveoColors, isDark = false)
        assertEquals(
            listOf(
                Color(0xFF8C5FF8).copy(alpha = 0.11f),
                Color(0xFF6366F1).copy(alpha = 0.075f),
                Color(0xFF8C5FF8).copy(alpha = 0.05f),
            ),
            layers.map { it.color },
        )
    }

    @Test
    fun `dark code block border and surfaces follow palette`() {
        val md = MarkdownTheme.resolveColors(ocean, isDark = true)
        assertEquals(ocean.primary.copy(alpha = 0.20f), md.codeBlockBorder)
        assertEquals(ocean.codeBlockBg, md.codeBlockBg)
        assertEquals(ocean.codeBlockHeaderBg, md.codeBlockSurface)
    }
}
