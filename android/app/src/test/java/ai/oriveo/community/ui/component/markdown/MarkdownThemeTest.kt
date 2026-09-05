package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.ui.theme.DarkOriveoColors
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
    fun `dark code block colors use deeper editor surface`() {
        val colors = MarkdownTheme.resolveColors(DarkOriveoColors, isDark = true)

        assertEquals(Color(0xFF050814), colors.codeBlockBg)
        assertEquals(Color(0xFF0B1020), colors.codeBlockSurface)
        assertEquals(Color(0xFFEAF1FB), colors.codeBlockFg)
        
        assertEquals(Color(0xFFC7D2E0), colors.codeBlockSecondary)
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
}
