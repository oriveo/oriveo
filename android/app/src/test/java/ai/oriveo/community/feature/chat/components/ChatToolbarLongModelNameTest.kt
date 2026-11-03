package ai.oriveo.community.feature.chat.components

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme
import dev.chrisbanes.haze.rememberHazeState
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Top-bar model row: long names wrap to two lines. A 6dp cyan dot precedes the realtime model name
 * (testTag matches iOS). The screen-reader description is the name and the state is "realtime voice",
 * so the name is read only once.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "en-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatToolbarLongModelNameTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun `toolbar model title uses two lines`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/ChatToolbar.kt").readText()
        val titleSource = source.requiredSlice(
            from = "text = modelName",
            to = "if (providerName.isNotEmpty())",
        )

        assertTrue(titleSource.contains("maxLines = 2"))
    }

    private var density = 1f

    private fun toolbar(isRealtime: Boolean): ComponentActivity {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                density = LocalDensity.current.density
                ChatToolbar(
                    providerKind = null,
                    providerName = "Provider",
                    modelName = MODEL,
                    isSendingMessage = false,
                    costText = "",
                    showMenu = false,
                    onBack = {},
                    onToggleModelSwitcher = {},
                    onNewChat = {},
                    onOpenMenu = {},
                    onDismissMenu = {},
                    onExportConversation = {},
                    onDeleteConversation = {},
                    showMemoryIndicator = false,
                    onOpenMemoryIndicator = {},
                    onOpenConversationSettings = {},
                    showInstructionsBadge = false,
                    hasMessages = false,
                    transparentChrome = true,
                    hazeState = rememberHazeState(),
                    trueTransparentBlurEnabled = false,
                    isRealtime = isRealtime,
                )
            }
        }
        composeRule.waitForIdle()
        return activity
    }

    /** Clear the composition before finishing, so the previous top bar's semantics node does not linger into the next lookup. */
    private fun ComponentActivity.close() {
        setContent {}
        composeRule.waitForIdle()
        finish()
    }

    @Test
    fun realtime_model_shows_cyan_dot_before_name() {
        val activity = toolbar(isRealtime = true)
        val dot = composeRule.onNodeWithTag(REALTIME_DOT, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val name = composeRule.onNodeWithText(MODEL, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertEquals("dot width", 6f, dot.width / density, 1f / density)
        assertEquals("dot height", 6f, dot.height / density, 1f / density)
        assertEquals("dot → name", 6f, (name.left - dot.right) / density, 1f / density)
        assertEquals("dot centered on the name", name.center.y, dot.center.y, density)
        val pixels = composeRule.onNodeWithTag(REALTIME_DOT, useUnmergedTree = true).captureToImage().toPixelMap()
        val center = pixels[pixels.width / 2, pixels.height / 2]
        assertEquals(0x22 / 255f, center.red, 0.02f)
        assertEquals(0xD3 / 255f, center.green, 0.02f)
        assertEquals(0xEE / 255f, center.blue, 0.02f)
        activity.close()
    }

    @Test
    fun realtime_dot_has_test_tag() {
        val realtime = toolbar(isRealtime = true)
        assertEquals(1, composeRule.onAllNodesWithTag(REALTIME_DOT, useUnmergedTree = true).fetchSemanticsNodes().size)
        realtime.close()
        val text = toolbar(isRealtime = false)
        assertEquals(0, composeRule.onAllNodesWithTag(REALTIME_DOT, useUnmergedTree = true).fetchSemanticsNodes().size)
        text.close()
    }

    @Test
    fun realtime_model_label_reads_realtime_voice() {
        val realtime = toolbar(isRealtime = true)
        val tag = realtime.getString(R.string.voice_realtime_model_tag)
        val row = composeRule.onNodeWithTag(MODEL_ROW).fetchSemanticsNode().config
        val spoken = row.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
        assertEquals(MODEL, spoken.first())
        assertEquals(tag, row.getOrNull(SemanticsProperties.StateDescription))
        // The name is read only once: other descriptions no longer include the model name, and the cyan dot itself is silent.
        assertTrue(spoken.toString(), spoken.drop(1).none { it.contains(MODEL) })
        val dot = composeRule.onNodeWithTag(REALTIME_DOT, useUnmergedTree = true).fetchSemanticsNode().config
        assertEquals(null, dot.getOrNull(SemanticsProperties.ContentDescription))
        realtime.close()

        val text = toolbar(isRealtime = false)
        val plainRow = composeRule.onNodeWithTag(MODEL_ROW).fetchSemanticsNode().config
        val plain = plainRow.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
        assertFalse(plain.toString(), plain.any { it.contains(tag) })
        assertEquals(null, plainRow.getOrNull(SemanticsProperties.StateDescription))
        text.close()
    }
}

private const val MODEL = "Test Live Model"
private const val REALTIME_DOT = "realtime_model_dot"
private const val MODEL_ROW = "chat_model_switcher_row"

private fun String.requiredSlice(from: String, to: String): String {
    val startIndex = indexOf(from)
    require(startIndex >= 0) { "Missing start boundary: $from" }
    val endIndex = indexOf(to, startIndex + from.length)
    require(endIndex >= 0) { "Missing end boundary: $to" }
    return substring(startIndex, endIndex)
}
