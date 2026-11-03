package ai.oriveo.community.feature.chat.composer

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
import ai.oriveo.community.feature.chat.voice.RealtimeBackToStageOrbTag
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** On the rendered button: after ■ turns back into ≋, taps within 500 ms (injected clock) do nothing. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ComposerActionClusterVoiceTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun `voice tap is ignored for 500 ms after stop and then starts the conversation`() {
        var now = 10_000L
        var generating by mutableStateOf(true)
        var stops = 0
        var starts = 0
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                ComposerActionCluster(
                    isGenerating = generating,
                    isPrimed = false,
                    enabled = true,
                    voiceAvailable = true,
                    onStartVoice = { starts++ },
                    clock = { now },
                    onClick = { stops++ },
                )
            }
        }
        composeRule.waitForIdle()
        val stop = activity.getString(R.string.stop)
        val voice = activity.getString(R.string.voice_conversation_start_a11y)

        composeRule.onNodeWithContentDescription(stop).performClick()
        assertEquals(1, stops)

        composeRule.runOnIdle { generating = false }
        composeRule.waitForIdle()
        now = 10_499L
        composeRule.onNodeWithContentDescription(voice).performClick()
        assertEquals("tap inside the re-arm window", 0, starts)

        now = 10_500L
        composeRule.onNodeWithContentDescription(voice).performClick()
        assertEquals(1, starts)
        assertEquals(1, stops)
    }

    @Test
    fun realtime_model_shows_back_to_stage_instead_of_voice() {
        var starts = 0
        var backs = 0
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                ComposerActionCluster(
                    isGenerating = false,
                    isPrimed = false,
                    enabled = true,
                    voiceAvailable = true,
                    onStartVoice = { starts++ },
                    backToStage = ComposerVoiceEntry.backToStage(isRealtime = true),
                    onBackToStage = { backs++ },
                    onClick = {},
                )
            }
        }
        composeRule.waitForIdle()
        val voice = activity.getString(R.string.voice_conversation_start_a11y)
        val back = activity.getString(R.string.voice_realtime_back_to_stage)

        composeRule.onAllNodesWithContentDescription(voice).assertCountEquals(0)
        // The slot shows the shared back-to-stage orb (both pages, E-528), read as before.
        composeRule.onNodeWithTag(RealtimeBackToStageOrbTag, useUnmergedTree = true)
            .assertContentDescriptionEquals(back)
        composeRule.onNodeWithContentDescription(back).performClick()
        assertEquals(1, backs)
        assertEquals(0, starts)
        // Text models keep ≋.
        assertEquals(false, ComposerVoiceEntry.backToStage(isRealtime = false))
    }
}
