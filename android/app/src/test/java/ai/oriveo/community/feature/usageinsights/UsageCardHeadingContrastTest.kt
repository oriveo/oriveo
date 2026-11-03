package ai.oriveo.community.feature.usageinsights

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import ai.oriveo.community.ui.theme.DarkBlackOriveoColors
import ai.oriveo.community.ui.theme.DarkForestOriveoColors
import ai.oriveo.community.ui.theme.DarkGraphiteOriveoColors
import ai.oriveo.community.ui.theme.DarkOceanOriveoColors
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.DarkPurpleOriveoColors
import ai.oriveo.community.ui.theme.DarkSunsetOriveoColors
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Usage cards draw `cardSheen` (white, 7/255 in dark) over `surface`. Must-read headings on
 * those cards use `textSecondary`: `textTertiary` passes on bare surface but drops to about
 * 4.34:1 once the overlay is composited. Mirrors iOS UsageCardHeadingContrastTests.
 */
class UsageCardHeadingContrastTest {

    private val darkPalettes = mapOf(
        "dark" to DarkOriveoColors,
        "dark-purple" to DarkPurpleOriveoColors,
        "dark-graphite" to DarkGraphiteOriveoColors,
        "dark-black" to DarkBlackOriveoColors,
        "dark-ocean" to DarkOceanOriveoColors,
        "dark-forest" to DarkForestOriveoColors,
        "dark-sunset" to DarkSunsetOriveoColors,
    )

    @Test
    fun `textSecondary meets 4_5 over surface plus card highlight for every dark palette`() {
        for ((id, colors) in darkPalettes) {
            val background = colors.cardSheen.compositeOver(colors.surface)
            val ratio = contrastRatio(colors.textSecondary, background)
            assertTrue("$id: textSecondary over highlighted surface is $ratio:1", ratio >= 4.5)
        }
    }

    @Test
    fun `heading anchors in the three usage cards use textSecondary`() {
        val expectations = listOf(
            Triple("BudgetCard.kt", "R.string.usage_monthly_budget_eyebrow", "Spacer(modifier = Modifier.weight(1f))"),
            Triple("CompositionCard.kt", "val eyebrowColor =", "maxLines = 1"),
            Triple("HeroCard.kt", "if (dateSubtitle != null) {", "append(dateSubtitle)"),
            Triple("HeroCard.kt", "R.string.usage_vs_last_month", "color = colors."),
        )
        for ((file, start, end) in expectations) {
            val slice = slice(source(file), start, end)
            assertNotNull("$file: anchor not found", slice)
            val window = slice!!
            assertFalse("$file: heading still uses textTertiary", window.contains("textTertiary"))
            assertTrue("$file: heading does not use textSecondary", window.contains("textSecondary"))
        }
    }

    @Test
    fun `composition eyebrow uses provider text tint only for a selected provider slice`() {
        val window = slice(source("CompositionCard.kt"), "val eyebrowColor =", "maxLines = 1")
        assertNotNull("CompositionCard.kt: eyebrow color anchor not found", window)
        val unselected = slice(window!!, "eyebrowSegment == null || eyebrowSegment.isOthers", "} else {")
        assertNotNull("CompositionCard.kt: unselected / Others branch not found", unselected)
        assertTrue("unselected / Others branch must use textSecondary", unselected!!.contains("colors.textSecondary"))
        val selected = window.substringAfter("} else {")
        assertTrue(
            "selected provider branch must use the provider text tint",
            selected.contains("providerTextTintFor(eyebrowSegment.providerKind, eyebrowSegment.providerId, OriveoTheme.isDark)"),
        )
        assertFalse("selected provider branch must not use the raw brand tint", selected.contains("providerTintFor("))
        assertTrue("eyebrow Text must use the computed color", window.contains("color = eyebrowColor,"))
    }

    private fun slice(source: String, start: String, end: String): String? {
        val from = source.indexOf(start)
        if (from < 0) return null
        val to = source.indexOf(end, from + start.length)
        if (to < 0) return null
        // Extend past the end anchor to the end of its line so the token name is included.
        val lineEnd = source.indexOf('\n', to).let { if (it < 0) source.length else it }
        return source.substring(from, lineEnd)
    }

    private fun source(file: String): String =
        File("src/main/java/ai/oriveo/community/feature/usageinsights/cards/$file").readText()

    private fun contrastRatio(foreground: Color, background: Color): Double {
        val a = foreground.luminance().toDouble()
        val b = background.luminance().toDouble()
        return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
    }
}
