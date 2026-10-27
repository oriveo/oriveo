package ai.oriveo.community.ui.theme

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Switching the dark palette does not rebuild the page: the same Activity, the same remember object, the input text and the list scroll position are all kept,
 * while the colors read have already switched to the new palette. The switch follows the production path: palette state (the preference collected by MainActivity) -> `OriveoTheme(palette =)`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DarkPaletteSwitchUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun `switching_palette_keeps_view_state`() {
        var palette by mutableStateOf(DarkPaletteChoice.Default)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val rememberedObjects = mutableListOf<Any>()
        var listState: LazyListState? = null
        var text by mutableStateOf("")
        var seenBackground = Color.Unspecified
        var seenPrimary = Color.Unspecified

        activity.setContent {
            OriveoTheme(darkTheme = true, palette = palette) {
                val marker = remember { Any() }
                if (rememberedObjects.lastOrNull() !== marker) rememberedObjects += marker
                val state = rememberLazyListState()
                listState = state
                seenBackground = OriveoTheme.colors.backgroundBase
                seenPrimary = OriveoTheme.colors.primary
                Column {
                    BasicTextField(
                        value = text,
                        onValueChange = { text = it },
                        modifier = Modifier.testTag("input"),
                    )
                    LazyColumn(state = state, modifier = Modifier.height(400.dp).testTag("list")) {
                        items(200) { index -> Text("row $index", modifier = Modifier.height(48.dp)) }
                    }
                }
            }
        }
        composeRule.waitForIdle()
        assertEquals(DarkOriveoColors.backgroundBase, seenBackground)

        composeRule.onNodeWithTag("input").performTextInput("draft kept")
        composeRule.onNodeWithTag("list").performScrollToIndex(120)
        composeRule.waitForIdle()
        val indexBefore = listState!!.firstVisibleItemIndex
        val offsetBefore = listState!!.firstVisibleItemScrollOffset
        val stateBefore = listState
        assertEquals(120, indexBefore)

        palette = DarkPaletteChoice.Preset(DarkPaletteId.Ocean)
        composeRule.waitForIdle()

        assertEquals("colors switch to the new palette", DarkOceanOriveoColors.backgroundBase, seenBackground)
        assertEquals(DarkOceanOriveoColors.primary, seenPrimary)
        assertNotEquals(DarkOriveoColors.backgroundBase, seenBackground)
        assertEquals("the same remember object", 1, rememberedObjects.size)
        assertSame("LazyListState is not rebuilt", stateBefore, listState)
        assertEquals("input text is kept", "draft kept", text)
        assertEquals("scroll position is kept", indexBefore, listState!!.firstVisibleItemIndex)
        assertEquals(offsetBefore, listState!!.firstVisibleItemScrollOffset)
        assertEquals("the Activity is not recreated", false, activity.isFinishing)

        // Switching the seed of a custom palette: colors are likewise re-read immediately without rebuilding state
        val seed = OriveoCustomPalette.presets.first()
        palette = DarkPaletteChoice.Custom(seed)
        composeRule.waitForIdle()
        assertEquals("custom palette colors", OriveoCustomPalette.colors(seed).primary, seenPrimary)
        assertEquals(OriveoCustomPalette.colors(seed).backgroundBase, seenBackground)
        assertEquals("the same remember object", 1, rememberedObjects.size)
        assertEquals("input text is kept", "draft kept", text)
    }
}
