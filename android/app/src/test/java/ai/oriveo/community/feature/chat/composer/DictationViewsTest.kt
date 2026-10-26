package ai.oriveo.community.feature.chat.composer

import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationFailedAction
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Rendering of the recording bar, busy row, mic key and dictation cards: real components, real semantics tree, real callbacks.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DictationViewsTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var activity: ComponentActivity

    private val levels = MutableStateFlow(listOf(0.2f, 0.6f, 1f))

    @Test
    fun `recording bar keys call discard, transcribe and transcribe-and-send`() {
        var discard = 0
        var transcribe = 0
        var send = 0
        launch {
            ComposerDictationBar(
                startedAt = START,
                levels = levels,
                canSend = true,
                onDiscard = { discard++ },
                onTranscribe = { transcribe++ },
                onTranscribeAndSend = { send++ },
                now = { START },
            )
        }

        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_discard_recording)).performClick()
        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribe)).performClick()
        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_transcribe_and_send))
            .assertIsEnabled()
            .performClick()
        composeRule.waitForIdle()

        assertEquals(1, discard)
        assertEquals(1, transcribe)
        assertEquals(1, send)
    }

    @Test
    fun `transcribe-and-send is disabled and silent when the host cannot send`() {
        var send = 0
        var transcribe = 0
        launch {
            ComposerDictationBar(
                startedAt = START,
                levels = levels,
                canSend = false,
                onDiscard = {},
                onTranscribe = { transcribe++ },
                onTranscribeAndSend = { send++ },
                now = { START },
            )
        }

        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_transcribe_and_send))
            .assertIsNotEnabled()
            .performClick()
        composeRule.waitForIdle()

        assertEquals(0, send)
        // Send being unavailable does not affect transcription itself
        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribe)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, transcribe)
    }

    @Test
    fun `timer starts at 0 00 and reads elapsed time from startedAt`() {
        launch { bar(startedAt = START, now = START) }
        composeRule.onNodeWithText("0:00").assertExists()
    }

    @Test
    fun `timer floors elapsed millis to whole seconds`() {
        launch { bar(startedAt = START, now = START + 65_900L) }
        composeRule.onNodeWithText("1:05").assertExists()
    }

    @Test
    fun `recording bar itself does not set keepScreenOn`() {
        val shown = mutableStateOf(true)
        var view: View? = null
        launch {
            view = LocalView.current
            if (shown.value) bar(startedAt = START, now = START)
        }
        val hostView = requireNotNull(view)
        // Keep-screen-on follows controller state (rememberDictationHost); whether the recording bar is in the composition does not change it.
        composeRule.onNodeWithText("0:00").assertExists()
        assertFalse(hostView.keepScreenOn)

        composeRule.runOnIdle { shown.value = false }
        composeRule.waitForIdle()
        assertFalse(hostView.keepScreenOn)
    }

    @Test
    fun `busy row shows only the cancel key and the transcribing label`() {
        var cancel = 0
        launch {
            ComposerDictationBusyRow(
                label = DictationText(R.string.voice_dictation_transcribing_with, listOf("Whisper")),
                onCancel = { cancel++ },
            )
        }

        composeRule.onNodeWithText(activity.getString(R.string.voice_dictation_transcribing_with, "Whisper"))
            .assertExists()
        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribe)).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_transcribe_and_send))
            .assertDoesNotExist()
        composeRule.onNodeWithText("0:00").assertDoesNotExist()

        composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_discard_recording)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, cancel)
    }

    @Test
    fun `busy label from the presentation rule renders without an engine name`() {
        val row = dictationInputRow(
            state = DictationState.Transcribing(SLOT, DictationSubmit.Insert),
            hostSlotKey = SLOT,
            engineInfo = DictationEngineInfo.System,
        ) as DictationInputRow.Busy
        launch { ComposerDictationBusyRow(label = row.label, onCancel = {}) }

        composeRule.onNodeWithText(str(R.string.voice_dictation_transcribing)).assertExists()
    }

    @Test
    fun `mic key calls back on tap`() {
        var taps = 0
        launch { DictationMicButton(onClick = { taps++ }) }

        composeRule.onNodeWithContentDescription(str(R.string.voice_dictate)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, taps)
    }

    @Test
    fun `card for failed retry renders failed title, recording saved, discard and retry`() {
        assertCardTexts(
            DictationState.Failed(SLOT, DictationFailedAction.Retry),
            pendingDurationSec = 12.0,
            title = appStr(R.string.voice_dictation_failed_title),
            subtitle = appStr(R.string.voice_dictation_recording_saved),
            secondary = appStr(R.string.voice_dictation_discard),
            primary = appStr(R.string.voice_dictation_retry),
        )
    }

    @Test
    fun `card for failed check-connection renders connection unavailable and check connection`() {
        assertCardTexts(
            DictationState.Failed(SLOT, DictationFailedAction.CheckConnection),
            pendingDurationSec = null,
            title = appStr(R.string.voice_dictation_failed_title),
            subtitle = appStr(R.string.voice_dictation_connection_unavailable),
            secondary = appStr(R.string.voice_dictation_discard),
            primary = appStr(R.string.voice_dictation_check_connection),
        )
    }

    @Test
    fun `card for failed no-transcript renders no text, recording saved, discard and retry`() {
        assertCardTexts(
            DictationState.Failed(SLOT, DictationFailedAction.NoTranscript),
            pendingDurationSec = null,
            title = appStr(R.string.voice_dictation_no_text),
            subtitle = appStr(R.string.voice_dictation_recording_saved),
            secondary = appStr(R.string.voice_dictation_discard),
            primary = appStr(R.string.voice_dictation_retry),
        )
    }

    @Test
    fun `card for interrupted renders the saved duration and transcribe recording`() {
        assertCardTexts(
            DictationState.Interrupted(SLOT),
            pendingDurationSec = 65.9,
            title = appStr(R.string.voice_dictation_interrupted),
            subtitle = app.getString(R.string.voice_dictation_saved_duration, "1:05"),
            secondary = appStr(R.string.voice_dictation_discard),
            primary = appStr(R.string.voice_dictation_transcribe_recording),
        )
    }

    @Test
    fun `card for slot occupied renders discard-and-rerecord and transcribe first`() {
        assertCardTexts(
            DictationState.SlotOccupied(SLOT),
            pendingDurationSec = 3_725.0,
            title = appStr(R.string.voice_dictation_slot_occupied),
            subtitle = app.getString(R.string.voice_dictation_saved_duration, "1:02:05"),
            secondary = appStr(R.string.voice_dictation_discard_and_rerecord),
            primary = appStr(R.string.voice_dictation_transcribe_first),
        )
    }

    @Test
    fun `card for denied renders mic denied, not now and open settings`() {
        assertCardTexts(
            DictationState.Denied,
            pendingDurationSec = null,
            title = appStr(R.string.voice_dictation_mic_denied_title),
            subtitle = appStr(R.string.voice_dictation_denied_subtitle),
            secondary = appStr(R.string.voice_dictation_not_now),
            primary = appStr(R.string.voice_dictation_open_settings),
        )
    }

    @Test
    fun `card secondary and primary buttons call back separately`() {
        val card = requireNotNull(
            dictationCard(DictationState.SlotOccupied(SLOT), SLOT, isBoundHost = true, pendingDurationSec = null),
        )
        var secondary = 0
        var primary = 0
        launch { DictationPromptCard(card = card, onSecondary = { secondary++ }, onPrimary = { primary++ }) }

        composeRule.onNodeWithText(appStr(R.string.voice_dictation_discard_and_rerecord)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, secondary)
        assertEquals(0, primary)

        composeRule.onNodeWithText(appStr(R.string.voice_dictation_transcribe_first)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, secondary)
        assertEquals(1, primary)
    }

    @Test
    fun `failed card shows the error status icon`() {
        launchCard(DictationState.Failed(SLOT, DictationFailedAction.CheckConnection))
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_ERROR_TAG, useUnmergedTree = true).assertExists()
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_WAVEFORM_TAG, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun `interrupted card shows the waveform status icon`() {
        launchCard(DictationState.Interrupted(SLOT), pendingDurationSec = 12.0)
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_WAVEFORM_TAG, useUnmergedTree = true).assertExists()
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_ERROR_TAG, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun `denied card shows the error status icon`() {
        launchCard(DictationState.Denied)
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_ERROR_TAG, useUnmergedTree = true).assertExists()
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_WAVEFORM_TAG, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun `slot occupied card shows the waveform status icon`() {
        launchCard(DictationState.SlotOccupied(SLOT), pendingDurationSec = 30.0)
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_WAVEFORM_TAG, useUnmergedTree = true).assertExists()
        composeRule.onNodeWithTag(DICTATION_CARD_ICON_ERROR_TAG, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun `card buttons hug their labels and sit at the trailing edge, card spans the host width`() {
        launchCard(DictationState.Failed(SLOT, DictationFailedAction.CheckConnection))
        val root = composeRule.onRoot().fetchSemanticsNode().boundsInRoot
        val card = composeRule.onNodeWithTag(DICTATION_CARD_TAG).fetchSemanticsNode().boundsInRoot
        val secondary = composeRule.onNodeWithTag(DICTATION_CARD_SECONDARY_TAG).fetchSemanticsNode().boundsInRoot
        val primary = composeRule.onNodeWithTag(DICTATION_CARD_PRIMARY_TAG).fetchSemanticsNode().boundsInRoot
        val density = cardDensity
        val contentPadding = cardPaddingDp * density

        // The card is as wide as the host (host horizontal padding matches the input box; the card adds no inset of its own)
        assertEquals(root.width, card.width, 1f)
        // The secondary button is a text button: sized to its label, not splitting the row evenly with the primary button
        assertTrue("secondary ${secondary.width} vs card ${card.width}", secondary.width < card.width / 3)
        assertTrue("primary ${primary.width} vs card ${card.width}", primary.width < card.width / 2)
        // Right-aligned: the primary button hugs the card content's right edge, the secondary button sits to its left
        assertEquals(card.right - contentPadding, primary.right, 2f * density)
        assertTrue("secondary $secondary primary $primary", secondary.right <= primary.left)
        // Touch target >= 44dp
        assertTrue("secondary h ${secondary.height} density $density", secondary.height >= 44f * density - 0.5f)
        assertTrue("primary h ${primary.height} density $density", primary.height >= 44f * density - 0.5f)
    }

    private fun launchCard(state: DictationState, pendingDurationSec: Double? = null) {
        val card = requireNotNull(dictationCard(state, SLOT, isBoundHost = true, pendingDurationSec = pendingDurationSec))
        launch {
            cardPaddingDp = OriveoTheme.layout.cardPadding.value
            // OriveoTheme may scale LocalDensity by screen width, so convert dp using the in-composition value
            cardDensity = androidx.compose.ui.platform.LocalDensity.current.density
            DictationPromptCard(card = card, onSecondary = {}, onPrimary = {})
        }
    }

    private var cardPaddingDp = 0f
    private var cardDensity = 1f

    private fun assertCardTexts(
        state: DictationState,
        pendingDurationSec: Double?,
        title: String,
        subtitle: String,
        secondary: String,
        primary: String,
    ) {
        val card = dictationCard(state, SLOT, isBoundHost = true, pendingDurationSec = pendingDurationSec)
        assertNotNull(card)
        launch { DictationPromptCard(card = card!!, onSecondary = {}, onPrimary = {}) }

        composeRule.onNodeWithText(title).assertExists()
        composeRule.onNodeWithText(subtitle).assertExists()
        composeRule.onNodeWithText(secondary).assertExists()
        composeRule.onNodeWithText(primary).assertExists()
    }

    @Composable
    private fun bar(startedAt: Long, now: Long) {
        ComposerDictationBar(
            startedAt = startedAt,
            levels = levels,
            canSend = true,
            onDiscard = {},
            onTranscribe = {},
            onTranscribeAndSend = {},
            now = { now },
        )
    }

    private fun launch(content: @Composable () -> Unit) {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent { OriveoTheme(darkTheme = false) { content() } }
        composeRule.waitForIdle()
    }

    private fun str(res: Int): String = activity.getString(res)

    // Expected card strings are evaluated before launch, using the application context
    private val app get() = RuntimeEnvironment.getApplication()

    private fun appStr(res: Int): String = app.getString(res)

    private companion object {
        const val START = 1_000_000L
        const val SLOT = "conversation:c1"
    }
}
