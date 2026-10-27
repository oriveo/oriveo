package ai.oriveo.community.feature.home

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.VectorGroup
import androidx.compose.ui.graphics.vector.VectorNode
import androidx.compose.ui.graphics.vector.VectorPath
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import ai.oriveo.community.core.navigation.AppRoute
import ai.oriveo.community.core.navigation.tabSelectedLabelColor
import ai.oriveo.community.ui.component.OriveoTabBarIcons
import ai.oriveo.community.ui.component.OriveoTabGlyph
import ai.oriveo.community.ui.theme.DarkForestOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.LocalIsDarkTheme
import ai.oriveo.community.ui.theme.LocalOriveoColors
import ai.oriveo.community.ui.theme.OriveoColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * No hard-coded dark colors: the dark branches of the home page and the bottom tabs must follow the current palette (dark-forest is used here, with a green primary and yellow-green secondary,
 * the farthest from the default purple), and the light values stay unchanged one by one.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DarkPaletteHomeColorTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private data class Captured(
        val sendFill: Color,
        val nameGradient: List<Color>,
        val accent: Color,
        val accentGlow: Color,
        val groupCardFill: Color,
        val dark: AuroraDarkColors?,
    )

    /** Composes once under the given light/dark mode and palette and takes the actual output of the production AuroraTheme accessors. */
    private fun capture(isDark: Boolean, colors: OriveoColors): Captured {
        var captured: Captured? = null
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            CompositionLocalProvider(LocalIsDarkTheme provides isDark, LocalOriveoColors provides colors) {
                captured = Captured(
                    sendFill = AuroraTheme.sendFill(),
                    nameGradient = AuroraTheme.nameGradient(),
                    accent = AuroraTheme.accent(),
                    accentGlow = AuroraTheme.accentGlow(),
                    groupCardFill = AuroraTheme.groupCardFill(),
                    dark = AuroraTheme.darkColors(),
                )
            }
        }
        composeRule.waitForIdle()
        return requireNotNull(captured)
    }

    @Test
    fun `dark home send key name gradient and glow follow the forest palette`() {
        val forest = DarkForestOriveoColors
        val c = capture(isDark = true, colors = forest)

        assertEquals(forest.primary, c.sendFill)
        assertEquals(listOf(forest.primary, forest.accent), c.nameGradient)
        assertEquals(forest.primary, c.accent)
        assertEquals(forest.accent, c.accentGlow)
        assertEquals(forest.surface, c.groupCardFill)

        // The three lights and the afterglow of the aurora crown / outer halo use only primary / accent, with intensity multiplied by the palette glowK
        val dark = requireNotNull(c.dark)
        assertEquals(setOf(forest.primary, forest.accent), setOf(dark.crownLeft, dark.crownMiddle, dark.crownRight, dark.crownWash))
        assertEquals(forest.glowK, dark.glowK)
        assertEquals(setOf(forest.primary, forest.accent), dark.ringColors.toSet())
        assertEquals(listOf(forest.background, forest.backgroundBase), listOf(dark.bgTop, dark.bgBottom))
    }

    @Test
    fun `light home colors are unchanged`() {
        val c = capture(isDark = false, colors = LightOriveoColors)

        assertEquals(Color(0xFF8B5CF6), c.sendFill)
        assertEquals(listOf(Color(0xFF8C5FF8), Color(0xFFD946EF)), c.nameGradient)
        assertEquals(Color(0xFF8B5CF6), c.accent)
        assertEquals(Color(0xFF8B5CF6), c.accentGlow)
        assertEquals(Color(0xFFFFFFFF), c.groupCardFill)
        assertNull(c.dark)
    }

    @Test
    fun `dark tab labels are the palette primary and light labels keep the measured tints`() {
        val forest = DarkForestOriveoColors
        listOf(AppRoute.Home, AppRoute.Providers, AppRoute.Settings).forEach { route ->
            assertEquals("$route", forest.primary, tabSelectedLabelColor(route, isDark = true, darkPrimary = forest.primary))
        }
        assertEquals(Color(0xFF7442EE), tabSelectedLabelColor(AppRoute.Home, isDark = false, darkPrimary = forest.primary))
        assertEquals(Color(0xFF007E75), tabSelectedLabelColor(AppRoute.Providers, isDark = false, darkPrimary = forest.primary))
        assertEquals(Color(0xFFDE3D00), tabSelectedLabelColor(AppRoute.Settings, isDark = false, darkPrimary = forest.primary))
    }

    @Test
    fun `dark tab icons all use the palette gradient brand and light keeps the three tints`() {
        val forest = DarkForestOriveoColors
        val brand = forest.primary to forest.accent
        OriveoTabGlyph.entries.forEach { glyph ->
            assertEquals("$glyph", brand, OriveoTabBarIcons.gradient(glyph, isDark = true, darkBrand = brand))
            // The gradient actually baked into the selected icon's stroke is also [primary, accent]
            assertEquals("$glyph", listOf(forest.primary, forest.accent), selectedStrokeColors(OriveoTabBarIcons.selected(glyph, isDark = true, darkBrand = brand)))
        }
        assertEquals(Color(0xFF8B5CF6) to Color(0xFF60A5FA), OriveoTabBarIcons.gradient(OriveoTabGlyph.Home, isDark = false))
        assertEquals(Color(0xFF0D9488) to Color(0xFF0EA5E9), OriveoTabBarIcons.gradient(OriveoTabGlyph.Providers, isDark = false))
        assertEquals(Color(0xFFEA580C) to Color(0xFFEC4899), OriveoTabBarIcons.gradient(OriveoTabGlyph.Settings, isDark = false))
    }

    /** Takes the gradient colors of the stroke brush of the selected icon's first path (LinearGradient.colors is internal, read via reflection). */
    @Suppress("UNCHECKED_CAST")
    private fun selectedStrokeColors(vector: ImageVector): List<Color> {
        val path = generateSequence(listOf<VectorNode>(vector.root)) { nodes ->
            nodes.flatMap { node -> if (node is VectorGroup) node.toList() else emptyList() }.takeIf { it.isNotEmpty() }
        }.flatten().filterIsInstance<VectorPath>().first()
        val brush = requireNotNull(path.stroke)
        val field = brush.javaClass.getDeclaredField("colors").apply { isAccessible = true }
        return field.get(brush) as List<Color>
    }
}
