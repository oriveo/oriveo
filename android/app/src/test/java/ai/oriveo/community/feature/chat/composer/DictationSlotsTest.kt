package ai.oriveo.community.feature.chat.composer

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.DictationCommands
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationFailedAction
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Input row switching and card slots: both components observe controller state, render for their own slot and wire buttons to the right commands.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DictationSlotsTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var activity: ComponentActivity

    private val commands = FakeCommands()
    private val actions = FakeActions()
    private val handle = DictationHostCoordinator(SLOT, commands, actions)

    init {
        // This handle is the controller's current host.
        commands.boundOwner.value = handle.owner
    }

    @Test
    fun `own-slot recording shows the recording bar wired to discard and finish`() {
        commands.state.value = DictationState.Recording(SLOT, START)
        launch { Switcher(handle, canSend = { true }) }

        composeRule.onNodeWithText(NORMAL).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_discard_recording)).performClick()
        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribe)).performClick()
        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_transcribe_and_send))
            .assertIsEnabled()
            .performClick()
        composeRule.waitForIdle()

        assertEquals(
            listOf("discard", "finish:${DictationSubmit.Insert}", "finish:${DictationSubmit.Send}"),
            commands.calls,
        )
    }

    @Test
    fun `transcribe-and-send is disabled when the host cannot send`() {
        commands.state.value = DictationState.Recording(SLOT, START)
        launch { Switcher(handle, canSend = { false }) }

        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_transcribe_and_send))
            .assertIsNotEnabled()
            .performClick()
        composeRule.waitForIdle()

        assertEquals(emptyList<String>(), commands.calls)
    }

    @Test
    fun `own-slot transcribing shows busy row with the cloud engine name and cancel discards`() {
        commands.engineInfo.value = DictationEngineInfo(displayName = "Whisper", providerId = "p1", isCloud = true)
        commands.state.value = DictationState.Transcribing(SLOT, DictationSubmit.Insert)
        launch { Switcher(handle, canSend = { true }) }

        composeRule.onNodeWithText(NORMAL).assertDoesNotExist()
        composeRule.onNodeWithText(activity.getString(R.string.voice_dictation_transcribing_with, "Whisper"))
            .assertExists()
        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_discard_recording)).performClick()
        composeRule.waitForIdle()

        assertEquals(listOf("discard"), commands.calls)
    }

    @Test
    fun `transcribing without a cloud engine shows the plain busy label`() {
        commands.state.value = DictationState.Transcribing(SLOT, DictationSubmit.Insert)
        launch { Switcher(handle, canSend = { true }) }

        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribing)).assertExists()
    }

    @Test
    fun `another slot's recording keeps the normal content and follows state changes`() {
        commands.state.value = DictationState.Recording(OTHER, START)
        launch { Switcher(handle, canSend = { true }) }

        composeRule.onNodeWithText(NORMAL).assertExists()
        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_discard_recording)).assertDoesNotExist()

        composeRule.runOnIdle { commands.state.value = DictationState.Recording(SLOT, START) }
        composeRule.waitForIdle()

        composeRule.onNodeWithText(NORMAL).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_discard_recording)).assertExists()
    }

    @Test
    fun `null handle renders only the normal content`() {
        launch { Switcher(null, canSend = { true }) }

        composeRule.onNodeWithText(NORMAL).assertExists()
    }

    @Test
    fun `failed card on own slot retries by inserting and discards`() {
        commands.state.value = DictationState.Failed(SLOT, DictationFailedAction.Retry)
        launch { DictationPromptSlot(handle) }

        composeRule.onNodeWithText(str(R.string.voice_dictation_failed_title)).assertExists()
        composeRule.onNodeWithText(str(R.string.voice_dictation_retry)).performClick()
        composeRule.onNodeWithText(str(R.string.voice_dictation_discard)).performClick()
        composeRule.waitForIdle()

        assertEquals(listOf("transcribeSaved:${DictationSubmit.Insert}", "discard"), commands.calls)
    }

    @Test
    fun `slot occupied card shows saved duration and wires both buttons`() {
        commands.pendingDurationSec.value = 75.9
        commands.state.value = DictationState.SlotOccupied(SLOT)
        launch { DictationPromptSlot(handle) }

        composeRule.onNodeWithText(str(R.string.voice_dictation_slot_occupied)).assertExists()
        composeRule.onNodeWithText(activity.getString(R.string.voice_dictation_saved_duration, "1:15")).assertExists()
        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribe_first)).performClick()
        composeRule.onNodeWithText(str(R.string.voice_dictation_discard_and_rerecord)).performClick()
        composeRule.waitForIdle()

        assertEquals(listOf("transcribeSaved:${DictationSubmit.Insert}", "discardAndRestart"), commands.calls)
    }

    @Test
    fun `denied card dismisses and opens settings through the host`() {
        commands.state.value = DictationState.Denied
        launch { DictationPromptSlot(handle) }

        composeRule.onNodeWithText(str(R.string.voice_dictation_mic_denied_title)).assertExists()
        composeRule.onNodeWithText(str(R.string.voice_dictation_not_now)).performClick()
        composeRule.onNodeWithText(str(R.string.voice_dictation_open_settings)).performClick()
        composeRule.waitForIdle()

        assertEquals(listOf("dismissDenied"), commands.calls)
        assertEquals(listOf("openAppSettings"), actions.calls)
    }

    @Test
    fun `denied card only on bound owner`() {
        val otherActions = FakeActions()
        val other = DictationHostCoordinator(SLOT, commands, otherActions)
        commands.state.value = DictationState.Denied
        launch {
            Column {
                DictationPromptSlot(handle)
                DictationPromptSlot(other)
            }
        }
        val title = str(R.string.voice_dictation_mic_denied_title)
        val openSettings = str(R.string.voice_dictation_open_settings)

        composeRule.onAllNodesWithText(title).assertCountEquals(1)
        composeRule.onNodeWithText(openSettings).performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("openAppSettings"), actions.calls)
        assertEquals(emptyList<String>(), otherActions.calls)

        // Another host with the same key takes over: the card appears only there.
        composeRule.runOnIdle { commands.boundOwner.value = other.owner }
        composeRule.waitForIdle()
        composeRule.onAllNodesWithText(title).assertCountEquals(1)
        composeRule.onNodeWithText(openSettings).performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("openAppSettings"), actions.calls)
        assertEquals(listOf("openAppSettings"), otherActions.calls)

        // No host: nobody shows the permission card.
        composeRule.runOnIdle { commands.boundOwner.value = null }
        composeRule.waitForIdle()
        composeRule.onAllNodesWithText(title).assertCountEquals(0)
    }

    @Test
    fun `card for another slot is not shown and appears when the state turns to this slot`() {
        commands.state.value = DictationState.Interrupted(OTHER)
        launch { DictationPromptSlot(handle) }

        composeRule.onNodeWithText(str(R.string.voice_dictation_interrupted)).assertDoesNotExist()

        composeRule.runOnIdle { commands.state.value = DictationState.Interrupted(SLOT) }
        composeRule.waitForIdle()

        composeRule.onNodeWithText(str(R.string.voice_dictation_interrupted)).assertExists()
        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribe_recording)).performClick()
        composeRule.waitForIdle()

        assertEquals(listOf("transcribeSaved:${DictationSubmit.Insert}"), commands.calls)
    }

    @Test
    fun `null handle shows no card`() {
        commands.state.value = DictationState.Denied
        launch {
            Column {
                DictationPromptSlot(null)
                Text(NORMAL)
            }
        }

        composeRule.onNodeWithText(NORMAL).assertExists()
        composeRule.onNodeWithText(str(R.string.voice_dictation_mic_denied_title)).assertDoesNotExist()
    }

    @Composable
    private fun Switcher(handle: DictationHostCoordinator?, canSend: () -> Boolean) {
        DictationInputSwitcher(handle = handle, canSend = canSend) { Text(NORMAL) }
    }

    private fun launch(content: @Composable () -> Unit) {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent { OriveoTheme(darkTheme = false) { content() } }
        composeRule.waitForIdle()
    }

    private fun str(res: Int): String = activity.getString(res)

    private class FakeCommands : DictationCommands {
        val calls = mutableListOf<String>()
        override val state = MutableStateFlow<DictationState>(DictationState.Idle)
        override val engineInfo = MutableStateFlow<DictationEngineInfo?>(null)
        override val pendingDurationSec = MutableStateFlow<Double?>(null)
        override val levelMeter = MutableStateFlow(listOf(0.2f, 0.6f, 1f))
        override val boundOwner = MutableStateFlow<Any?>(null)

        override fun start(slotKey: String) {
            calls += "start:$slotKey"
        }

        override fun finish(submit: DictationSubmit) {
            calls += "finish:$submit"
        }

        override fun discard() {
            calls += "discard"
        }

        override fun transcribeSaved(submit: DictationSubmit) {
            calls += "transcribeSaved:$submit"
        }

        override fun discardAndRestart() {
            calls += "discardAndRestart"
        }

        override fun dismissDenied() {
            calls += "dismissDenied"
        }

        override fun undoDiscard(slotKey: String): Boolean {
            calls += "undoDiscard:$slotKey"
            return true
        }

        override fun bind(slotKey: String, owner: Any) {
            calls += "bind:$slotKey"
        }

        override fun detach(slotKey: String, owner: Any) {
            calls += "detach:$slotKey"
        }
    }

    private class FakeActions : DictationHostActions {
        val calls = mutableListOf<String>()

        override fun insert(text: String) {
            calls += "insert:$text"
        }

        override fun canSend(): Boolean = true

        override fun send() {
            calls += "send"
        }

        override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) {
            calls += "toast"
        }

        override fun openAppSettings() {
            calls += "openAppSettings"
        }

        override fun openProviderDetail(providerId: String) {
            calls += "openProviderDetail:$providerId"
        }

        override fun openProviderSetup() {
            calls += "openProviderSetup"
        }

        override fun openVoiceSettings() {
            calls += "openVoiceSettings"
        }
    }

    private companion object {
        const val START = 1_000_000L
        const val SLOT = "conversation:c1"
        const val OTHER = "conversation:c2"
        const val NORMAL = "normal composer row"
    }
}
