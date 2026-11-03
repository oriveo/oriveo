package ai.oriveo.community.ui.component

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.SwitchColors
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createComposeRule
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The checked thumb must be the theme's switchThumb token (white, like iOS) under every brand palette and
 * both appearances, never M3's colorScheme.onPrimary. Covers purple / amber (sunset) / teal (ocean) plus the rest.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class OriveoSwitchColorsTest {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun `checked thumb uses switchThumb token for every palette in light and dark`() {
        val cases = DarkPaletteId.entries.flatMap { id -> listOf(false, true).map { dark -> id to dark } }
        val results = mutableMapOf<Pair<DarkPaletteId, Boolean>, Pair<SwitchColors, Color>>()
        composeRule.setContent {
            Column {
                cases.forEach { (id, dark) ->
                    OriveoTheme(darkTheme = dark, palette = DarkPaletteChoice.Preset(id)) {
                        results[id to dark] = oriveoSwitchColors() to OriveoTheme.colors.switchThumb
                    }
                }
            }
        }
        composeRule.waitForIdle()

        assertEquals(cases.size, results.size)
        listOf(DarkPaletteId.Purple, DarkPaletteId.Sunset, DarkPaletteId.Ocean).forEach { id ->
            assertTrue("missing case for $id", results.containsKey(id to false) && results.containsKey(id to true))
        }
        results.forEach { (case, pair) ->
            val (switchColors, thumbToken) = pair
            assertEquals("checked thumb for $case", thumbToken, switchColors.checkedThumbColor)
            assertEquals("switchThumb token for $case is white", Color.White, thumbToken)
        }
    }
}
