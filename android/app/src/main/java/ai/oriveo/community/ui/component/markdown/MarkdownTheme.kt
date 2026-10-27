package ai.oriveo.community.ui.component.markdown

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
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
    /** Text color of the controls on a code block header (language pill, copy, expand): #52525B in light, same as the code body in dark. */
    val codeBlockHeaderText: Color,

    // Syntax highlighting: the 12 roles of "Oriveo Code"
    val syntaxText: Color,
    val syntaxKeyword: Color,
    val syntaxString: Color,
    val syntaxNumber: Color,
    val syntaxFunction: Color,
    val syntaxType: Color,
    val syntaxProperty: Color,
    val syntaxComment: Color,
    val syntaxPunctuation: Color,
    val syntaxDiffAdd: Color,
    val syntaxDiffDelete: Color,
    val syntaxDiffHunk: Color,
    /** Whole-line background of added / deleted diff lines (the role color at an alpha). */
    val syntaxDiffAddLine: Color,
    val syntaxDiffDeleteLine: Color,

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
        val isDark = OriveoTheme.isDark
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
        // Oriveo Code light: a light code block background, identical on all three platforms
        codeBlockBg = OriveoCodeColors.Light.codeBg,
        codeBlockSurface = OriveoCodeColors.Light.codeHeaderBg,
        codeBlockBorder = c.primary.copy(alpha = 0.22f), // light brand ink at 22%
        codeBlockFg = OriveoCodeColors.Light.text,
        codeBlockSecondary = OriveoCodeColors.Light.headerText,
        codeBlockHeaderText = OriveoCodeColors.Light.headerText,
        syntaxText = OriveoCodeColors.Light.text,
        syntaxKeyword = OriveoCodeColors.Light.keyword,
        syntaxString = OriveoCodeColors.Light.string,
        syntaxNumber = OriveoCodeColors.Light.number,
        syntaxFunction = OriveoCodeColors.Light.function,
        syntaxType = OriveoCodeColors.Light.type,
        syntaxProperty = OriveoCodeColors.Light.property,
        syntaxComment = OriveoCodeColors.Light.comment,
        syntaxPunctuation = OriveoCodeColors.Light.punctuation,
        syntaxDiffAdd = OriveoCodeColors.Light.diffAdd,
        syntaxDiffDelete = OriveoCodeColors.Light.diffDelete,
        syntaxDiffHunk = OriveoCodeColors.Light.diffHunk,
        syntaxDiffAddLine = OriveoCodeColors.Light.diffAddLine,
        syntaxDiffDeleteLine = OriveoCodeColors.Light.diffDeleteLine,
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
        // Inline code follows the dark palette: text = secondary accent (the second information layer), fill = white 7%
        inlineCodeText = c.accent,
        inlineCodeBg = Color.White.copy(alpha = 0.07f),
        // Code block fill / header follow the dark palette (JSON codeBg / codeHeaderBg)
        codeBlockBg = c.codeBlockBg,
        codeBlockSurface = c.codeBlockHeaderBg,
        codeBlockBorder = c.primary.copy(alpha = 0.20f),
        codeBlockFg = OriveoCodeColors.Dark.text,
        // Lifted: #9AA8BD only reached a marginal 5.5:1 against the very dark
        // codeBlockBg (#050814). #C7D2E0 reaches 8:1, which makes the language pill and
        // the line-number gutter legible.
        codeBlockSecondary = Color(0xFFC7D2E0),
        codeBlockHeaderText = OriveoCodeColors.Dark.text,
        // Syntax colors do not follow the dark palette: the palette only changes the code block background
        syntaxText = OriveoCodeColors.Dark.text,
        syntaxKeyword = OriveoCodeColors.Dark.keyword,
        syntaxString = OriveoCodeColors.Dark.string,
        syntaxNumber = OriveoCodeColors.Dark.number,
        syntaxFunction = OriveoCodeColors.Dark.function,
        syntaxType = OriveoCodeColors.Dark.type,
        syntaxProperty = OriveoCodeColors.Dark.property,
        syntaxComment = OriveoCodeColors.Dark.comment,
        syntaxPunctuation = OriveoCodeColors.Dark.punctuation,
        syntaxDiffAdd = OriveoCodeColors.Dark.diffAdd,
        syntaxDiffDelete = OriveoCodeColors.Dark.diffDelete,
        syntaxDiffHunk = OriveoCodeColors.Dark.diffHunk,
        syntaxDiffAddLine = OriveoCodeColors.Dark.diffAddLine,
        syntaxDiffDeleteLine = OriveoCodeColors.Dark.diffDeleteLine,
        quoteBorder = c.primary.copy(alpha = 0.5f),
        // The dark textSecondary (#B4BAC6) is already the right value here, so reuse it.
        quoteText = c.textSecondary,
        // Tables follow the dark palette: border = palette border (JSON shared.border, white 10%),
        // header = surfaceRaised (OriveoColors.surfaceElevated), cell = surface, zebra row = bgInset (OriveoColors.surfaceInset)
        tableBorder = c.border,
        tableHeaderBg = c.surfaceElevated,
        tableCellBg = c.surface,
        tableAltRowBg = c.surfaceInset,
    )
}

/**
 * Fixed colors of the "Oriveo Code" syntax highlighting, mirroring the shared code-highlight contract.
 * One set per appearance; dark does not follow the palette, and the code block background in dark comes from the palette codeBg / codeHeaderBg.
 */
internal object OriveoCodeColors {

    object Light {
        val codeBg = Color(0xFFF4F4F5)
        val codeHeaderBg = Color(0xFFE4E4E7)
        val headerText = Color(0xFF52525B)
        val text = Color(0xFF18181B)
        val keyword = Color(0xFF7C3AED)
        val string = Color(0xFF13773A)
        val number = Color(0xFFB5400C)
        val function = Color(0xFF1D4ED8)
        val type = Color(0xFF8F5B00)
        val property = Color(0xFF0E7490)
        val comment = Color(0xFF6B6B76)
        val punctuation = Color(0xFF52525B)
        val diffAdd = Color(0xFF13773A)
        val diffDelete = Color(0xFFB91C1C)
        val diffHunk = Color(0xFF0E7490)
        val diffAddLine = Color(0xFF10B981).copy(alpha = 0.10f)
        val diffDeleteLine = Color(0xFFEF4444).copy(alpha = 0.10f)
    }

    object Dark {
        val text = Color(0xFFE4E4E7)
        val keyword = Color(0xFFCBA6F7)
        val string = Color(0xFFA6E3A1)
        val number = Color(0xFFFAB387)
        val function = Color(0xFF89B4FA)
        val type = Color(0xFFF9E2AF)
        val property = Color(0xFF89DCEB)
        val comment = Color(0xFF9399B2)
        val punctuation = Color(0xFFA6ADC8)
        val diffAdd = Color(0xFFA6E3A1)
        val diffDelete = Color(0xFFF38BA8)
        val diffHunk = Color(0xFF89DCEB)
        val diffAddLine = Color(0xFF6EE7A1).copy(alpha = 0.12f)
        val diffDeleteLine = Color(0xFFF8978F).copy(alpha = 0.12f)
    }
}
