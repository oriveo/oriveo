package ai.oriveo.community.feature.chat.voice

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Voice glyphs: the list maps one-to-one to ic_voice_* resources, and each loads via painterResource at 24dp with a 24x24 viewport. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceGlyphsTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun `glyph list matches ic_voice resources one to one`() {
        val resources = R.drawable::class.java.fields
            .filter { it.name.startsWith("ic_voice_") }
            .associate { it.getInt(null) to it.name }
        assertEquals(
            setOf(
                "ic_voice_close_w700", "ic_voice_close_w600", "ic_voice_mic_w500", "ic_voice_mic_off_w500",
                "ic_voice_graphic_eq_w600", "ic_voice_arrow_upward_w700", "ic_voice_language_w600",
                "ic_voice_keyboard_w500", "ic_voice_check_w600",
            ),
            resources.values.toSet(),
        )
        assertEquals(VoiceGlyphs.all.size, VoiceGlyphs.all.toSet().size)
        assertEquals(resources.keys, VoiceGlyphs.all.toSet())
    }

    @Test
    fun `every glyph loads through painterResource at 24dp with a 24x24 viewport`() {
        val sizes = mutableMapOf<Int, Size>()
        val expected = mutableMapOf<Int, Size>()
        val vectors = mutableMapOf<Int, ImageVector>()
        Robolectric.buildActivity(ComponentActivity::class.java).setup().get().setContent {
            val px = with(LocalDensity.current) { 24.dp.toPx() }
            VoiceGlyphs.all.forEach { id ->
                sizes[id] = painterResource(id).intrinsicSize
                expected[id] = Size(px, px)
                vectors[id] = ImageVector.vectorResource(id)
            }
        }
        composeRule.waitForIdle()
        assertEquals(VoiceGlyphs.all.size, sizes.size)
        VoiceGlyphs.all.forEach { id ->
            assertEquals(expected[id], sizes[id])
            val vector = vectors.getValue(id)
            assertEquals(24f, vector.viewportWidth)
            assertEquals(24f, vector.viewportHeight)
            assertEquals(24.dp, vector.defaultWidth)
            assertEquals(false, vector.autoMirror)
        }
    }
}
