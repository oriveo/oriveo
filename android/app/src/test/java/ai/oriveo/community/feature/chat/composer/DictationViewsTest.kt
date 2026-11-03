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
import androidx.compose.ui.graphics.Color
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteId
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
 * Rendering behavior of the recording bar / busy row / mic key / dictation cards (contract items 1, 2, 6): real components, real semantic tree, real callbacks.
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
        // Send being unavailable does not affect transcription itself.
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
        // Keep-screen-on follows the controller state (rememberDictationHost); whether the recording bar is in the composition does not change it.
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
    fun `card for failed no-transcript renders no text, the language hint, retry and change language`() {
        assertCardTexts(
            DictationState.Failed(SLOT, DictationFailedAction.NoTranscript, language = "en-US"),
            pendingDurationSec = null,
            title = appStr(R.string.voice_dictation_no_text),
            subtitle = app.getString(
                R.string.voice_dictation_no_text_body,
                languageName("en-US", java.util.Locale.getDefault()),
            ),
            secondary = appStr(R.string.voice_dictation_retry),
            primary = appStr(R.string.voice_dictation_action_change_language),
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
        // v3 floating card: inner padding 18
        val contentPadding = 18f * density

        // The card is as wide as the host (the host's horizontal inset matches the input box; the card does not inset itself).
        assertEquals(root.width, card.width, 1f)
        // Both buttons size to their labels rather than splitting a row evenly.
        assertTrue("secondary ${secondary.width} vs card ${card.width}", secondary.width < card.width / 3)
        assertTrue("primary ${primary.width} vs card ${card.width}", primary.width < card.width / 2)
        // Right-aligned: the primary button hugs the card content's right edge, the secondary button sits to its left with a 10 gap.
        assertEquals(card.right - contentPadding, primary.right, 2f * density)
        assertEquals(10f * density, primary.left - secondary.right, 1f * density)
        // v3 capsule buttons: minimum height 40 (large font sizes grow the height with the content).
        assertTrue("secondary height ${secondary.height}", secondary.height >= 40f * density - 0.5f)
        assertTrue("primary height ${primary.height}", primary.height >= 40f * density - 0.5f)
    }

    @Test
    fun `at 200 percent text the failed card buttons and the done key keep their labels whole and grow past 40`() {
        val card = requireNotNull(dictationCard(DictationState.Failed(SLOT, DictationFailedAction.Retry), SLOT, isBoundHost = true, pendingDurationSec = null))
        launchScaled(2f) { DictationPromptCard(card = card, onSecondary = {}, onPrimary = {}) }
        val problems = mutableListOf<String>()
        listOf(DICTATION_CARD_SECONDARY_TAG to card.secondary.label, DICTATION_CARD_PRIMARY_TAG to card.primary.label).forEach { (tag, label) ->
            val button = composeRule.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
            val text = composeRule.onNodeWithText(str(label), useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            checkGrows(tag, button, text, problems)
        }
        activity.finish()

        launchScaled(2f) { bar(startedAt = START, now = START) }
        val done = str(R.string.voice_dictation_transcribe)
        val button = composeRule.onNodeWithText(done).fetchSemanticsNode().boundsInRoot
        val text = composeRule.onNodeWithText(done, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        checkGrows("done", button, text, problems)
        assertTrue("200% font scale: $problems", problems.isEmpty())
    }

    @Test
    fun `at 200 percent text on 300, 360 and 402 dp screens the done key and timer stay whole in every locale and the keys stay on screen`() {
        // Same as iOS: the done label and timer take their full width first, the waveform takes the remainder (it may shrink to 0 bars); if still not enough, shrink the font to 0.75, never truncate or wrap.
        val locales = listOf("en", "zh-rCN", "zh-rTW", "ja", "ko", "de", "fr", "es", "pt-rBR", "ru", "ar", "hi", "in", "th", "tr", "vi")
        val elapsed = 599_000L // 9:59
        val problems = mutableListOf<String>()
        // 360 / 402 are regression locks (the original font size may still fit); 300 dp is below the floor, used to prove the path of shrinking the font to 0.75.
        for (width in listOf(300, 360, 402)) {
            for (locale in locales) {
                RuntimeEnvironment.setQualifiers("+$locale-w${width}dp-h800dp")
                val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
                activity = controller.get()
                activity.setContent {
                    OriveoTheme(darkTheme = false) {
                        val density = androidx.compose.ui.platform.LocalDensity.current
                        scaledDensity = density.density
                        androidx.compose.runtime.CompositionLocalProvider(
                            androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(density.density, 2f),
                        ) { bar(startedAt = START, now = START + elapsed) }
                    }
                }
                composeRule.waitForIdle()
                val where = "$width/$locale"
                val rootWidth = composeRule.onRoot().fetchSemanticsNode().boundsInRoot.width
                val done = str(R.string.voice_dictation_transcribe)
                val timer = formatDictationDuration(elapsed / 1000.0)
                listOf("done" to done, "timer" to timer).forEach { (name, text) ->
                    val node = composeRule.onNodeWithText(text, useUnmergedTree = true).fetchSemanticsNode()
                    val results = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    node.config[androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult].action?.invoke(results)
                    val layout = results.single()
                    if (layout.lineCount != 1 || layout.hasVisualOverflow || layout.isLineEllipsized(0)) {
                        problems += "$where $name clipped: '$text' lines=${layout.lineCount} overflow=${layout.hasVisualOverflow}"
                    }
                    // The font shrinks to at most 0.75 (15 sp → 11.25 sp).
                    if (layout.layoutInput.style.fontSize.value < 15f * 0.75f - 0.01f) {
                        problems += "$where $name shrunk below 0.75: ${layout.layoutInput.style.fontSize}"
                    }
                    val bounds = node.boundsInRoot
                    if (bounds.left < -0.5f || bounds.right > rootWidth + 0.5f) problems += "$where $name off screen $bounds"
                }
                val doneButton = composeRule.onNodeWithText(done).fetchSemanticsNode().boundsInRoot
                val timerText = composeRule.onNodeWithText(timer, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                // Timer and done key do not overlap (they swap left/right under RTL).
                if (timerText.right > doneButton.left + 0.5f && doneButton.right > timerText.left + 0.5f) problems += "$where timer $timerText overlaps done $doneButton"
                listOf(
                    "discard" to str(R.string.voice_dictation_discard_recording),
                    "send" to str(R.string.voice_dictation_transcribe_and_send),
                ).forEach { (name, label) ->
                    val b = composeRule.onNodeWithContentDescription(label).fetchSemanticsNode().boundsInRoot
                    if (b.left < -0.5f || b.right > rootWidth + 0.5f || b.width < 44f * scaledDensity - 0.5f) {
                        problems += "$where $name $b root $rootWidth"
                    }
                }
                val capsule = composeRule.onNodeWithTag(DICTATION_CAPSULE_TAG).fetchSemanticsNode().boundsInRoot
                if (capsule.height < 56f * scaledDensity - 0.5f) problems += "$where capsule ${capsule.height}"
                if (doneButton.top < capsule.top - 0.5f || doneButton.bottom > capsule.bottom + 0.5f) {
                    problems += "$where done $doneButton outside capsule $capsule"
                }
                // Destroy one by one, otherwise the previous round's semantic tree remains and the next round would find two trees.
                controller.pause().stop().destroy()
                composeRule.waitForIdle()
            }
        }
        assertTrue("200% font scale, narrow screen: $problems", problems.isEmpty())
    }

    @Test
    fun `waveform drops to the newest bars that fit and keeps 22 when wide enough`() {
        // 3 dp per bar + minimum gap 1 dp, 4 dp left and right.
        assertEquals(22, dictationVisibleBarCount(widthDp = 200f))
        assertEquals(22, dictationVisibleBarCount(widthDp = 8f + 22 * 4f - 1f))
        assertEquals(21, dictationVisibleBarCount(widthDp = 8f + 22 * 4f - 1.5f))
        assertEquals(1, dictationVisibleBarCount(widthDp = 11f))
        assertEquals(0, dictationVisibleBarCount(widthDp = 10f))
        assertEquals(0, dictationVisibleBarCount(widthDp = 0f))
    }

    /** Button taller than 40, the text block sits inside the button with 8 dp inner padding top and bottom (with a fixed height of 40 the text touches the edges when large, and gets clipped when larger). */
    private fun checkGrows(
        name: String,
        button: androidx.compose.ui.geometry.Rect,
        text: androidx.compose.ui.geometry.Rect,
        problems: MutableList<String>,
    ) {
        val d = scaledDensity
        if (button.height <= 40f * d) problems += "$name height ${button.height / d} dp"
        // 8 dp inner vertical padding top and bottom (same as the iOS card button .padding(.vertical, 8)); the button grows with the text height.
        val inset = 8f * d - 1f
        if (text.top - button.top < inset || button.bottom - text.bottom < inset) {
            problems += "$name text ${text.height / d} dp in button ${button.height / d} dp (needs 8 dp above and below)"
        }
    }

    @Test
    fun `recording capsule is 56 high and the send key is a 56 circle`() {
        launch {
            barDensity = androidx.compose.ui.platform.LocalDensity.current.density
            bar(startedAt = START, now = START)
        }
        val capsule = composeRule.onNodeWithTag(DICTATION_CAPSULE_TAG).fetchSemanticsNode().boundsInRoot
        val send = composeRule.onNodeWithContentDescription(str(R.string.voice_dictation_transcribe_and_send))
            .fetchSemanticsNode().boundsInRoot

        assertEquals(56f * barDensity, capsule.height, 0.5f)
        assertEquals(56f * barDensity, send.width, 0.5f)
        assertEquals(56f * barDensity, send.height, 0.5f)
        // Send button sits to the right of the capsule, 10 gap.
        assertEquals(10f * barDensity, send.left - capsule.right, 1f * barDensity)
    }

    @Test
    fun `waveform has 22 bars sized by the contract formula, newest on the right`() {
        val full = List(30) { 1f }
        val heights = dictationWaveBarHeights(full)
        assertEquals(22, heights.size)
        heights.forEachIndexed { i, h ->
            val expected = 4 + Math.round(22 * (0.8 + 0.2 * Math.sin(1.9 * i)).coerceIn(0.0, 1.0)).toInt()
            assertEquals("bar $i", expected.toFloat(), h, 0.001f)
        }

        // Only one level: lands on the rightmost bar, the others are silent base height 4.
        val single = dictationWaveBarHeights(listOf(0.5f))
        assertEquals(22, single.size)
        assertTrue(single.dropLast(1).all { it == 4f })
        val last = 4 + Math.round(22 * (0.5 * (0.8 + 0.2 * Math.sin(1.9 * 21))).coerceIn(0.0, 1.0)).toInt()
        assertEquals(last.toFloat(), single.last(), 0.001f)

        // Over-range clamps to 1; the highest 26 does not exceed the 28 waveform area.
        assertTrue(dictationWaveBarHeights(List(22) { 3f }).all { it in 4f..26f })
        assertEquals(List(22) { 4f }, dictationWaveBarHeights(emptyList()))

        // The i-th bar takes color ring k→k+1, k = floor(i / 22 × 4).
        assertEquals(DICTATION_WAVE_COLORS[0] to DICTATION_WAVE_COLORS[1], dictationWaveBarColors(0))
        assertEquals(DICTATION_WAVE_COLORS[0] to DICTATION_WAVE_COLORS[1], dictationWaveBarColors(5))
        assertEquals(DICTATION_WAVE_COLORS[1] to DICTATION_WAVE_COLORS[2], dictationWaveBarColors(6))
        assertEquals(DICTATION_WAVE_COLORS[3] to DICTATION_WAVE_COLORS[4], dictationWaveBarColors(21))
    }

    @Test
    fun `glow border turns once per 6 s from 24 degrees and stays at 24 under reduced motion`() {
        listOf(0L, 1_500L, 3_000L, 5_999L, 6_000L, 123_456L).forEach { t ->
            assertEquals("reduced at $t", 24f, dictationGlowDegrees(t, reduceMotion = true), 0.001f)
        }
        assertEquals(24f, dictationGlowDegrees(0L, reduceMotion = false), 0.001f)
        assertEquals(114f, dictationGlowDegrees(1_500L, reduceMotion = false), 0.001f)
        assertEquals(204f, dictationGlowDegrees(3_000L, reduceMotion = false), 0.001f)
        assertEquals(24f, dictationGlowDegrees(6_000L, reduceMotion = false), 0.001f)
    }

    private fun launchCard(state: DictationState, pendingDurationSec: Double? = null) {
        val card = requireNotNull(dictationCard(state, SLOT, isBoundHost = true, pendingDurationSec = pendingDurationSec))
        launch {
            // OriveoTheme may scale LocalDensity by screen width, so convert dp using the in-composition value.
            cardDensity = androidx.compose.ui.platform.LocalDensity.current.density
            DictationPromptCard(card = card, onSecondary = {}, onPrimary = {})
        }
    }

    private var cardDensity = 1f
    private var scaledDensity = 1f

    /** [content] at system text size [fontScale] (LocalDensity inside OriveoTheme keeps its density). */
    private fun launchScaled(fontScale: Float, content: @Composable () -> Unit) {
        launch {
            val density = androidx.compose.ui.platform.LocalDensity.current
            scaledDensity = density.density
            androidx.compose.runtime.CompositionLocalProvider(
                androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(density.density, fontScale),
            ) { content() }
        }
    }
    private var barDensity = 1f

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

    @Test
    fun `disabled send key fill is the palette brand ink at 12 percent in light and white at 10 percent in dark`() {
        // v3 voice contract: the unavailable ↑ in light mode = current palette brand ink α.12 (varies with the palette, same as iOS brand ink); dark mode fixed white α.10.
        val ocean = DarkPaletteChoice.Preset(DarkPaletteId.Ocean)
        val cases = listOf(
            Triple(false, DarkPaletteChoice.Default, DarkPaletteChoice.Default.lightBrand.ink.copy(alpha = 0.12f)),
            Triple(false, ocean, ocean.lightBrand.ink.copy(alpha = 0.12f)),
            Triple(true, DarkPaletteChoice.Default, Color.White.copy(alpha = 0.10f)),
            Triple(true, ocean, Color.White.copy(alpha = 0.10f)),
        )
        assertTrue(
            "palettes must differ in brand ink for the case to mean anything",
            DarkPaletteChoice.Default.lightBrand.ink != ocean.lightBrand.ink,
        )
        val fills = arrayOfNulls<Color>(cases.size)
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            cases.forEachIndexed { i, (dark, palette, _) ->
                OriveoTheme(darkTheme = dark, palette = palette) { fills[i] = dictationSendDisabledFill() }
            }
        }
        composeRule.waitForIdle()
        cases.forEachIndexed { i, (dark, palette, expected) ->
            assertEquals("dark=$dark palette=$palette", expected, fills[i])
        }
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

    // The expected card copy is evaluated before launch, using the application context.
    private val app get() = RuntimeEnvironment.getApplication()

    private fun appStr(res: Int): String = app.getString(res)

    private companion object {
        const val START = 1_000_000L
        const val SLOT = "conversation:c1"
    }
}
