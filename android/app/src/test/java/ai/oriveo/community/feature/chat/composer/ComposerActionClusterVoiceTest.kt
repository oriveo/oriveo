package ai.oriveo.community.feature.chat.composer

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
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
}
