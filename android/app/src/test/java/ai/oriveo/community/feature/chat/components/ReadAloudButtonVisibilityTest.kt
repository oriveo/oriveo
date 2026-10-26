package ai.oriveo.community.feature.chat.components

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Hidden cases of the read-aloud button: nothing is rendered when the speakable text is empty or the message is not eligible (early return, no controller injected). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ReadAloudButtonVisibilityTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val app = RuntimeEnvironment.getApplication()

    /** Any semantics entry whose value equals the read-aloud button's sentryTag. */
    private val readAloudTag = SemanticsMatcher("sentryTag chat_message_read_aloud_button") { node ->
        node.config.any { it.value == "chat_message_read_aloud_button" }
    }

    private fun show(messageText: String, eligible: Boolean) {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                ReadAloudButton(messageId = "msg-1", messageText = messageText, eligible = eligible)
            }
        }
        composeRule.waitForIdle()
    }

    private fun assertHidden() {
        composeRule.onAllNodes(readAloudTag).assertCountEquals(0)
        composeRule.onAllNodesWithContentDescription(app.getString(R.string.voice_read_aloud)).assertCountEquals(0)
        composeRule.onAllNodesWithContentDescription(app.getString(R.string.voice_stop_reading)).assertCountEquals(0)
    }

    @Test
    fun `empty text hides the button`() {
        show(messageText = "", eligible = true)
        assertHidden()
    }

    @Test
    fun `whitespace and markup only reply hides the button`() {
        // Shared fixture speakable-text.v1.json > whitespace_and_markup_only_reply
        show(messageText = "  \n\n---\n\n**  **\n", eligible = true)
        assertHidden()
    }

    @Test
    fun `ineligible message hides the button even with speakable text`() {
        show(messageText = "Hello there. This is a normal reply.", eligible = false)
        assertHidden()
    }
}
