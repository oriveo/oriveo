package ai.oriveo.community.ui.component.markdown

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme

/** Colour set used for Markdown rendering. */
@Immutable
data class MarkdownColors(
    // Text
    val text: Color,
    val textSecondary: Color,
    val link: Color,

    // Inline code
    val inlineCodeText: Color,
    val inlineCodeBg: Color,

    // Code block
    val codeBlockBg: Color,
    val codeBlockSurface: Color,
    val codeBlockBorder: Color,
    val codeBlockFg: Color,
    val codeBlockSecondary: Color,

    // Syntax highlighting
    val syntaxKeyword: Color,
    val syntaxString: Color,
    val syntaxComment: Color,
    val syntaxNumber: Color,
    val syntaxType: Color,
    val syntaxVariable: Color,

    // Block quote
    val quoteBorder: Color,
    val quoteText: Color,

    // Table: a solid card with zebra striping.
    val tableBorder: Color,
    val tableHeaderBg: Color,
    val tableCellBg: Color,
    val tableAltRowBg: Color,
)

object MarkdownTheme {

    @Composable
    fun colors(): MarkdownColors {
        val c = OriveoTheme.colors
        val isDark = c.backgroundBase == DarkOriveoColors.backgroundBase
        return resolveColors(c, isDark)
    }

    internal fun resolveColors(
        c: ai.oriveo.community.ui.theme.OriveoColors,
        isDark: Boolean,
    ): MarkdownColors = if (isDark) darkColors(c) else lightColors(c)

    private fun lightColors(c: ai.oriveo.community.ui.theme.OriveoColors) = MarkdownColors(
        text = c.textPrimary,
        textSecondary = c.textSecondary,
        link = c.primary,
        inlineCodeText = Color(0xFF0F172A),
        inlineCodeBg = Color(0xFFE2E8F0),
        codeBlockBg = Color(0xFF0B1220),
        codeBlockSurface = Color(0xFF111A2E),
        codeBlockBorder = Color(0x388C5FF8),          // 22%
        codeBlockFg = Color(0xFFE7EEF8),
        // Code blocks sit on a dark background in both light and dark themes, so the
        // language label and line numbers use the same lifted colour as the dark theme.
        codeBlockSecondary = Color(0xFFC7D2E0),
        syntaxKeyword = Color(0xFFD8B4FE),            // soft purple
        syntaxString = Color(0xFFA7F3D0),             // mint
        // Comments often run for many lines, so they are lifted to #94A3B8 to reach a
        // contrast ratio above 7:1 on the dark code background.
        syntaxComment = Color(0xFF94A3B8),            // muted slate
        syntaxNumber = Color(0xFFFDE68A),             // soft amber
        syntaxType = Color(0xFF7DD3FC),               // sky
        syntaxVariable = Color(0xFF5EEAD4),           // teal
        quoteBorder = c.primary.copy(alpha = 0.5f),
        // Quote body text does not use the global textSecondary (#6B7280): against the
        // pale lavender chat background it washes out. #52525B is one step darker and
        // stays readable.
        quoteText = Color(0xFF52525B),
        // The table palette is a solid white card with zebra striping rather than a
        // translucent surface, so the page background never shows through.
        tableBorder = Color(0xFFCBD5E1),
        tableHeaderBg = Color(0xFFF1F5F9),
        tableCellBg = Color(0xFFFFFFFF),
        tableAltRowBg = Color(0xFFF8FAFC),
    )

    private fun darkColors(c: ai.oriveo.community.ui.theme.OriveoColors) = MarkdownColors(
        text = c.textPrimary,
        textSecondary = c.textSecondary,
        link = c.primary,
        inlineCodeText = Color(0xFFE2E8F0),
        inlineCodeBg = Color(0xFF1E293B),
        codeBlockBg = Color(0xFF050814),
        codeBlockSurface = Color(0xFF0B1020),
        codeBlockBorder = Color(0x33C4B5FD),         // 20%
        codeBlockFg = Color(0xFFEAF1FB),
        // Lifted: #9AA8BD only reached a marginal 5.5:1 against the very dark
        // codeBlockBg (#050814). #C7D2E0 reaches 8:1, which makes the language pill and
        // the line-number gutter legible.
        codeBlockSecondary = Color(0xFFC7D2E0),
        syntaxKeyword = Color(0xFFD8B4FE),
        syntaxString = Color(0xFFA7F3D0),
        // Lifted: #7D8AA2 was only 5.5:1 on #050814, and comments often run for many
        // lines. #94A3B8 pushes it above 7:1.
        syntaxComment = Color(0xFF94A3B8),
        syntaxNumber = Color(0xFFFDE68A),
        syntaxType = Color(0xFF7DD3FC),
        syntaxVariable = Color(0xFF5EEAD4),
        quoteBorder = c.primary.copy(alpha = 0.5f),
        // The dark textSecondary (#B4BAC6) is already the right value here, so reuse it.
        quoteText = c.textSecondary,
        tableBorder = Color(0xFF334155),
        tableHeaderBg = Color(0xFF1E293B),
        tableCellBg = Color(0xFF0F172A),
        tableAltRowBg = Color(0xFF131C2E),
    )
}
