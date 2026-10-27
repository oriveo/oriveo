package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.ui.theme.DarkPaletteContract
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.LightOriveoColors
import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownThemeTest {

    @Test
    fun `light code block colors use editor surface`() {
        val colors = MarkdownTheme.resolveColors(LightOriveoColors, isDark = false)

        assertEquals(Color(0xFF0B1220), colors.codeBlockBg)
        assertEquals(Color(0xFF111A2E), colors.codeBlockSurface)
        assertEquals(Color(0xFFE7EEF8), colors.codeBlockFg)

        assertEquals(Color(0xFFC7D2E0), colors.codeBlockSecondary)
    }

    @Test
    fun `dark code block colors follow every dark palette`() {
        for (palette in DarkPaletteId.entries) {
            val json = DarkPaletteContract.palette(palette.id)
            val colors = MarkdownTheme.resolveColors(palette.colors, isDark = true)

            assertEquals("${palette.id} codeBg", DarkPaletteContract.color(json.getValue("codeBg")), colors.codeBlockBg)
            assertEquals("${palette.id} codeHeaderBg", DarkPaletteContract.color(json.getValue("codeHeaderBg")), colors.codeBlockSurface)
            assertEquals(Color(0xFFEAF1FB), colors.codeBlockFg)
            assertEquals(Color(0xFFC7D2E0), colors.codeBlockSecondary)
            assertEquals(palette.colors.primary, colors.link)
            assertEquals(palette.colors.textPrimary, colors.text)
        }
    }

    @Test
    fun `syntax colors stay balanced across themes`() {
        val colors = MarkdownTheme.resolveColors(LightOriveoColors, isDark = false)

        assertEquals(Color(0xFFD8B4FE), colors.syntaxKeyword)
        assertEquals(Color(0xFFA7F3D0), colors.syntaxString)

        assertEquals(Color(0xFF94A3B8), colors.syntaxComment)
        assertEquals(Color(0xFFFDE68A), colors.syntaxNumber)
        assertEquals(Color(0xFF7DD3FC), colors.syntaxType)
        assertEquals(Color(0xFF5EEAD4), colors.syntaxVariable)
    }
    @Test
    fun `dark inline code and table follow palette`() {
        for (id in listOf("dark-forest", "dark-sunset")) {
            val palette = DarkPaletteId.entries.first { it.id == id }
            val json = DarkPaletteContract.palette(id)
            val colors = MarkdownTheme.resolveColors(palette.colors, isDark = true)

            // Inline code: text = JSON accent, fill = white 7%
            assertEquals("$id accent", DarkPaletteContract.color(json.getValue("accent")), colors.inlineCodeText)
            assertEquals(Color.White.copy(alpha = 0.07f), colors.inlineCodeBg)
            assertEquals("$id surfaceRaised", DarkPaletteContract.color(json.getValue("surfaceRaised")), colors.tableHeaderBg)
            assertEquals("$id surface", DarkPaletteContract.color(json.getValue("surface")), colors.tableCellBg)
            assertEquals("$id bgInset", DarkPaletteContract.color(json.getValue("bgInset")), colors.tableAltRowBg)
            // Border = JSON shared.border rgba(255,255,255,0.10)
            assertEquals("$id border", Color(0x1AFFFFFF), colors.tableBorder)
        }
    }

    @Test
    fun `light inline code and table stay unchanged`() {
        val colors = MarkdownTheme.resolveColors(LightOriveoColors, isDark = false)

        assertEquals(Color(0xFF0F172A), colors.inlineCodeText)
        assertEquals(Color(0xFFE2E8F0), colors.inlineCodeBg)
        assertEquals(Color(0xFFF1F5F9), colors.tableHeaderBg)
        assertEquals(Color(0xFFCBD5E1), colors.tableBorder)
        assertEquals(Color(0xFFFFFFFF), colors.tableCellBg)
        assertEquals(Color(0xFFF8FAFC), colors.tableAltRowBg)
    }
}
