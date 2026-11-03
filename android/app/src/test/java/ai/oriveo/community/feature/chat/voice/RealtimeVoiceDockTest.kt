package ai.oriveo.community.feature.chat.voice

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.feature.home.homescreen.ModelSelectorPill
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Voice dock for the realtime model on the chat page: same panel as the stage; idle copy, a "switch to typing" capsule centered in the bottom row, and no mute or end button. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RealtimeVoiceDockTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private var starts = 0
    private var keyboards = 0

    private var modelSelects = 0

    private var catalogRetries = 0

    private fun show(
        preparing: Boolean = false,
        catalogFailed: Boolean = false,
        catalogRetrying: androidx.compose.runtime.State<Boolean> = androidx.compose.runtime.mutableStateOf(false),
        header: (@Composable () -> Unit)? = null,
    ): ComponentActivity {
        // The orb has a per-frame clock: auto-advance is off, so time is advanced explicitly before asserting.
        composeRule.mainClock.autoAdvance = false
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                // No navigation bar inset: the panel's bottom edge is the host's bottom edge, so button positions can be measured directly.
                RealtimeVoiceDock(
                    onStart = { starts++ },
                    onKeyboard = { keyboards++ },
                    modifier = Modifier.testTag(HOST),
                    navigationBarInset = false,
                    header = header,
                    preparing = preparing,
                    catalogFailed = catalogFailed,
                    catalogRetrying = catalogRetrying.value,
                    onRetryCatalog = { catalogRetries++ },
                )
            }
        }
        composeRule.mainClock.advanceTimeBy(300)
        composeRule.waitForIdle()
        return activity
    }

    @Test
    fun idle_dock_reads_tap_to_start_and_starts_on_tap() {
        val activity = show()
        val prompt = activity.getString(R.string.voice_realtime_tap_to_start)
        assertEquals("Tap to start talking", prompt)
        composeRule.onNodeWithContentDescription(prompt).assertHasClickAction().performClick()
        composeRule.mainClock.advanceTimeBy(100)
        assertEquals(1, starts)
        assertEquals(0, keyboards)
        activity.finish()
    }

    @Test
    fun keyboard_button_has_screen_reader_label_and_switches_to_typing() {
        val activity = show()
        val label = activity.getString(R.string.voice_realtime_switch_to_keyboard)
        // The "switch to typing" capsule centered in the bottom row: its visible text is the screen-reader name; height 36, horizontally centered.
        // Its center line matches the mute / end buttons during a session: button bottom = stageButtonBottom (stage bottom to screen bottom), plus half of a 64 button (1 dp tolerance for pixel rounding).
        val root = composeRule.onRoot().getBoundsInRoot()
        val host = composeRule.onNodeWithTag(HOST).getBoundsInRoot()
        val chip = composeRule.onNodeWithTag(RealtimeVoiceDockKeyboardTag)
            .assertTextEquals(label)
            .assertHeightIsEqualTo(36.dp)
            .getBoundsInRoot()
        assertEquals(((host.left + host.right) / 2).value, ((chip.left + chip.right) / 2).value, 1f)
        // Stage bottom to screen bottom, same as production: negative values are not counted (0 when this host is taller than the window).
        val buttonBottom = stageButtonBottom((root.bottom - host.bottom).coerceAtLeast(0.dp))
        assertEquals(
            (buttonBottom + StageButtonSize / 2).value,
            (host.bottom - (chip.top + chip.bottom) / 2).value,
            1f,
        )
        composeRule.onNodeWithText(label).assertHasClickAction().performClick()
        composeRule.mainClock.advanceTimeBy(100)
        assertEquals(1, keyboards)
        assertEquals(0, starts)
        activity.finish()
    }

    @Test
    fun idle_dock_has_no_mute() {
        val activity = show()
        composeRule.onAllNodesWithTag("voice_conversation_mute_button").assertCountEquals(0)
        composeRule.onAllNodesWithContentDescription(activity.getString(R.string.voice_conversation_mute_a11y))
            .assertCountEquals(0)
        composeRule.onAllNodesWithContentDescription(activity.getString(R.string.voice_conversation_unmute_a11y))
            .assertCountEquals(0)
        // No end button: the dock has only two clickable nodes, the orb and the "switch to typing" capsule.
        composeRule.onAllNodesWithTag("voice_conversation_end_button").assertCountEquals(0)
        composeRule.onAllNodes(hasClickAction()).assertCountEquals(2)
        // The orb is the same size as the stage: 148 (content height at least 366).
        composeRule.onNodeWithTag(RealtimeVoiceDockOrbTag).assertWidthIsEqualTo(148.dp).assertHeightIsEqualTo(148.dp)
        val host = composeRule.onNodeWithTag(HOST).getBoundsInRoot()
        assertEquals(true, (host.bottom - host.top).value >= 366f - 0.5f)
        activity.finish()
    }

    @Test
    fun home_dock_shows_model_pill_with_realtime_dot() {
        val model = AIModel(id = "gpt-realtime", name = "GPT Realtime", isDefault = true)
        val active = HomeViewModel.ActiveModel(
            provider = Provider(
                id = "provider-1",
                kind = ProviderKind.OpenAI,
                status = ProviderConnectionState.Connected,
                models = listOf(model),
            ),
            model = model,
        )
        // The home page passes the same pill as the home card: same click tag, same picker callback.
        val activity = show {
            ModelSelectorPill(
                activeModel = active,
                hasProvider = true,
                onModelSelect = { modelSelects++ },
                onAddProvider = {},
                realtime = true,
            )
        }
        val host = composeRule.onNodeWithTag(HOST).getBoundsInRoot()
        val pill = composeRule.onNodeWithTag("model_picker_button")
            .assert(
                SemanticsMatcher.expectValue(
                    SemanticsProperties.StateDescription,
                    activity.getString(R.string.voice_realtime_model_tag),
                ),
            )
            .getBoundsInRoot()
        composeRule.onNodeWithTag("realtime_model_dot", useUnmergedTree = true).assertExists()
        // Top-centered; 12 dp from the pill bottom to the orb box top.
        assertEquals(((host.left + host.right) / 2).value, ((pill.left + pill.right) / 2).value, 1f)
        val orb = composeRule.onNodeWithTag(RealtimeVoiceDockOrbTag).getBoundsInRoot()
        assertEquals(StageHeaderGap.value, (orb.top - pill.bottom).value, 1f)
        composeRule.onNodeWithTag("model_picker_button").performClick()
        composeRule.mainClock.advanceTimeBy(100)
        assertEquals(1, modelSelects)
        assertEquals(0, starts)
        activity.finish()
    }

    /** Catalog load failed: the failure card on the dock offers only one action, "retry"; the button is disabled while retrying; "switch to typing" stays clickable, and the orb does not start a session. */
    @Test
    fun catalogFailureCardOffersRetryOnly() {
        val retrying = androidx.compose.runtime.mutableStateOf(false)
        val activity = show(preparing = true, catalogFailed = true, catalogRetrying = retrying)
        composeRule.onNodeWithTag("voice_realtime_failure_card").assertExists()
        composeRule.onNodeWithText(activity.getString(R.string.voice_realtime_catalog_unavailable)).assertExists()
        composeRule.onAllNodesWithTag("voice_realtime_failure_action_open_connection").assertCountEquals(0)
        // The only action on the card is retry; the clickable nodes are the retry button and the "switch to typing" capsule (the orb is not clickable).
        composeRule.onNodeWithTag("voice_realtime_failure_action_retry")
            .assertTextEquals(activity.getString(R.string.voice_realtime_action_retry))
            .performClick()
        composeRule.mainClock.advanceTimeBy(100)
        assertEquals(1, catalogRetries)
        composeRule.onAllNodes(hasClickAction()).assertCountEquals(2)

        retrying.value = true
        composeRule.mainClock.advanceTimeBy(100)
        composeRule.onNodeWithTag("voice_realtime_failure_action_retry").assertIsNotEnabled().performClick()
        composeRule.mainClock.advanceTimeBy(100)
        assertEquals(1, catalogRetries)

        composeRule.onNodeWithTag(RealtimeVoiceDockKeyboardTag).performClick()
        composeRule.mainClock.advanceTimeBy(100)
        assertEquals(1, keyboards)
        assertEquals(0, starts)
        activity.finish()
    }

    private companion object {
        const val HOST = "realtime_voice_dock_host"
    }
}
