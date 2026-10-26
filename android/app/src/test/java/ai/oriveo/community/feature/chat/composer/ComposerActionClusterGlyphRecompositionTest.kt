package ai.oriveo.community.feature.chat.composer

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composer
import androidx.compose.runtime.CompositionTracer
import androidx.compose.runtime.InternalComposeTracingApi
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The main key does not recompose during the ≋ to ↑ morph: when pasting into an empty draft the morph and the
 * input layout land in the same few frames, and AnimatedContent recomposed AnimatedContentImpl /
 * AnimatedEnterExitImpl every frame (pasteOverLimit60k went from 9 to 13 Compose recompositions, P90 +6 to 11%).
 * The morph may only change layer properties: after the frame of the state switch, no composable function
 * should run again until the animation finishes.
 */
@OptIn(InternalComposeTracingApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ComposerActionClusterGlyphRecompositionTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val composed = mutableListOf<String>()
    private var tracing = false

    private val tracer = object : CompositionTracer {
        override fun traceEventStart(key: Int, dirty1: Int, dirty2: Int, info: String) {
            if (tracing) composed += info
        }

        override fun traceEventEnd() = Unit

        override fun isTraceInProgress(): Boolean = true
    }

    @After
    fun tearDown() {
        Composer.setTracer(null)
    }

    @Test
    fun `voice to send glyph morph does not recompose during the animation`() {
        var primed by mutableStateOf(false)
        val context = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        Composer.setTracer(tracer)
        context.setContent {
            OriveoTheme(darkTheme = false) {
                ComposerActionCluster(
                    isGenerating = false,
                    isPrimed = primed,
                    enabled = true,
                    voiceAvailable = true,
                    onClick = {},
                )
            }
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(context.getString(R.string.voice_conversation_start_a11y)).assertExists()

        composeRule.mainClock.autoAdvance = false
        tracing = true
        primed = true
        Snapshot.sendApplyNotifications()
        // The frame of the state switch must recompose (the icon target value changes); from the next frame on only layer updates are expected.
        composeRule.mainClock.advanceTimeByFrame()
        assertTrue("The frame of the state switch should recompose, otherwise this test measures nothing", composed.isNotEmpty())
        composed.clear()
        repeat(ANIMATION_FRAMES) { composeRule.mainClock.advanceTimeByFrame() }
        tracing = false
        composeRule.mainClock.autoAdvance = true
        composeRule.waitForIdle()

        assertEquals("Composable functions ran during the morph: $composed", emptyList<String>(), composed)
        composeRule.onNodeWithContentDescription(context.getString(R.string.send)).assertExists()
        composeRule.onNodeWithContentDescription(context.getString(R.string.voice_conversation_start_a11y)).assertDoesNotExist()
    }

    @Test
    fun `send to stop leaves only the stop glyph announced`() {
        var generating by mutableStateOf(false)
        val context = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        context.setContent {
            OriveoTheme(darkTheme = false) {
                ComposerActionCluster(
                    isGenerating = generating,
                    isPrimed = true,
                    enabled = true,
                    voiceAvailable = true,
                    onClick = {},
                )
            }
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(context.getString(R.string.send)).assertExists()

        generating = true
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(context.getString(R.string.stop)).assertExists()
        composeRule.onNodeWithContentDescription(context.getString(R.string.send)).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(context.getString(R.string.voice_conversation_start_a11y)).assertDoesNotExist()
    }

    private companion object {
        /** 16 ms per frame, covering the 180 ms enter morph. */
        const val ANIMATION_FRAMES = 15
    }
}
