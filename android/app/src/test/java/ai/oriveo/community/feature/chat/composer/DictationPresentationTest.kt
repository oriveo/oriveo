package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationEvent
import ai.oriveo.community.core.voice.DictationFailedAction
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.core.voice.VoiceFallbackReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Card, input row, duration text and toast specs. */
class DictationPresentationTest {
    private val host = "conv:1"
    private val other = "conv:2"

    private fun card(
        state: DictationState,
        bound: Boolean = true,
        duration: Double? = null,
    ) = dictationCard(state, hostSlotKey = host, isBoundHost = bound, pendingDurationSec = duration)

    private val discard = DictationCardButton(R.string.voice_dictation_discard, DictationCardAction.Discard)

    @Test
    fun `six cards follow the contract table`() {
        val saved = DictationText(R.string.voice_dictation_recording_saved)
        assertEquals(
            DictationCard(
                R.string.voice_dictation_failed_title,
                saved,
                discard,
                DictationCardButton(R.string.voice_dictation_retry, DictationCardAction.Retry),
                DictationCardIcon.Error,
            ),
            card(DictationState.Failed(host, DictationFailedAction.Retry)),
        )
        assertEquals(
            DictationCard(
                R.string.voice_dictation_failed_title,
                DictationText(R.string.voice_dictation_connection_unavailable),
                discard,
                DictationCardButton(R.string.voice_dictation_check_connection, DictationCardAction.CheckConnection),
                DictationCardIcon.Error,
            ),
            card(DictationState.Failed(host, DictationFailedAction.CheckConnection)),
        )
        assertEquals(
            DictationCard(
                R.string.voice_dictation_no_text,
                saved,
                discard,
                DictationCardButton(R.string.voice_dictation_retry, DictationCardAction.Retry),
                DictationCardIcon.Error,
            ),
            card(DictationState.Failed(host, DictationFailedAction.NoTranscript)),
        )
        assertEquals(
            DictationCard(
                R.string.voice_dictation_interrupted,
                DictationText(R.string.voice_dictation_saved_duration, listOf("0:47")),
                discard,
                DictationCardButton(R.string.voice_dictation_transcribe_recording, DictationCardAction.TranscribeRecording),
                DictationCardIcon.Waveform,
            ),
            card(DictationState.Interrupted(host), duration = 47.6),
        )
        assertEquals(
            DictationCard(
                R.string.voice_dictation_slot_occupied,
                DictationText(R.string.voice_dictation_saved_duration, listOf("1:00:00")),
                DictationCardButton(R.string.voice_dictation_discard_and_rerecord, DictationCardAction.DiscardAndRerecord),
                DictationCardButton(R.string.voice_dictation_transcribe_first, DictationCardAction.TranscribeFirst),
                DictationCardIcon.Waveform,
            ),
            card(DictationState.SlotOccupied(host), duration = 3600.0),
        )
        assertEquals(
            DictationCard(
                R.string.voice_dictation_mic_denied_title,
                DictationText(R.string.voice_dictation_denied_subtitle),
                DictationCardButton(R.string.voice_dictation_not_now, DictationCardAction.NotNow),
                DictationCardButton(R.string.voice_dictation_open_settings, DictationCardAction.OpenSettings),
                DictationCardIcon.Error,
            ),
            card(DictationState.Denied),
        )
    }

    @Test
    fun `denied card uses error icon`() {
        assertEquals(DictationCardIcon.Error, card(DictationState.Denied)?.icon)
    }

    @Test
    fun `slot occupied card uses waveform icon`() {
        assertEquals(DictationCardIcon.Waveform, card(DictationState.SlotOccupied(host))?.icon)
        assertEquals(DictationCardIcon.Waveform, card(DictationState.SlotOccupied(host), duration = 12.0)?.icon)
    }

    @Test
    fun `missing duration falls back to recording saved`() {
        val saved = DictationText(R.string.voice_dictation_recording_saved)
        assertEquals(saved, card(DictationState.Interrupted(host))?.subtitle)
        assertEquals(saved, card(DictationState.SlotOccupied(host))?.subtitle)
    }

    @Test
    fun `idle recording and transcribing show no card`() {
        assertNull(card(DictationState.Idle))
        assertNull(card(DictationState.Recording(host, startedAt = 10L)))
        assertNull(card(DictationState.Transcribing(host, DictationSubmit.Insert)))
    }

    @Test
    fun `other slot shows no card`() {
        assertNull(card(DictationState.Failed(other, DictationFailedAction.Retry)))
        assertNull(card(DictationState.Interrupted(other), duration = 5.0))
        assertNull(card(DictationState.SlotOccupied(other)))
    }

    @Test
    fun `denied shows only on the bound host`() {
        assertNull(card(DictationState.Denied, bound = false))
        assertEquals(R.string.voice_dictation_mic_denied_title, card(DictationState.Denied, bound = true)?.title)
    }

    @Test
    fun `input row has three shapes`() {
        val cloud = DictationEngineInfo(displayName = "My OpenAI", providerId = "p1", isCloud = true)
        assertEquals(
            DictationInputRow.Recording(startedAt = 42L),
            dictationInputRow(DictationState.Recording(host, 42L), host, DictationEngineInfo.System),
        )
        assertEquals(
            DictationInputRow.Busy(DictationText(R.string.voice_dictation_transcribing_with, listOf("My OpenAI"))),
            dictationInputRow(DictationState.Transcribing(host, DictationSubmit.Send), host, cloud),
        )
        assertEquals(
            DictationInputRow.Busy(DictationText(R.string.voice_dictation_transcribing)),
            dictationInputRow(DictationState.Transcribing(host, DictationSubmit.Insert), host, DictationEngineInfo.System),
        )
        assertEquals(
            DictationInputRow.Busy(DictationText(R.string.voice_dictation_transcribing)),
            dictationInputRow(
                DictationState.Transcribing(host, DictationSubmit.Insert),
                host,
                cloud.copy(displayName = null),
            ),
        )
        assertEquals(DictationInputRow.Normal, dictationInputRow(DictationState.Idle, host, cloud))
        assertEquals(DictationInputRow.Normal, dictationInputRow(DictationState.Recording(other, 1L), host, cloud))
        assertEquals(
            DictationInputRow.Normal,
            dictationInputRow(DictationState.Transcribing(other, DictationSubmit.Insert), host, cloud),
        )
        assertEquals(DictationInputRow.Normal, dictationInputRow(DictationState.Interrupted(host), host, cloud))
    }

    @Test
    fun `duration floors to seconds and switches to hours`() {
        assertEquals("0:00", formatDictationDuration(0.0))
        assertEquals("0:47", formatDictationDuration(47.0))
        assertEquals("0:59", formatDictationDuration(59.9))
        assertEquals("59:59", formatDictationDuration(3599.0))
        assertEquals("1:00:00", formatDictationDuration(3600.0))
    }

    @Test
    fun `eight events map to toast specs`() {
        assertNull(dictationToast(DictationEvent.Insert(host, "hi"), host))
        assertNull(dictationToast(DictationEvent.Send(host, "hi"), host))
        assertEquals(
            DictationToastSpec(R.string.voice_dictation_no_speech, GlobalToastStyle.Info, 3_000L),
            dictationToast(DictationEvent.NoSpeech(host), host),
        )
        assertEquals(
            DictationToastSpec(R.string.voice_dictation_engine_fallback, GlobalToastStyle.Info, 3_000L),
            dictationToast(DictationEvent.EngineFallback(host, VoiceFallbackReason.KeyMissing), host),
        )
        assertEquals(
            DictationToastSpec(
                R.string.voice_dictation_discarded,
                GlobalToastStyle.Removed,
                4_000L,
                undoSlotKey = host,
                undoLabel = R.string.voice_dictation_undo,
            ),
            dictationToast(DictationEvent.DiscardUndoable(host), host),
        )
        assertEquals(
            DictationToastSpec(
                message = R.string.voice_dictation_system_unavailable,
                style = GlobalToastStyle.Warning,
                durationMillis = 6_000L,
                actionLabel = R.string.voice_settings_action,
                action = DictationToastAction.OpenVoiceSettings,
            ),
            dictationToast(DictationEvent.SystemUnavailable(host), host),
        )
        assertEquals(
            DictationToastSpec(R.string.voice_dictation_recognizer_failed, GlobalToastStyle.Warning, 3_000L),
            dictationToast(DictationEvent.SystemRecognizerFailed(host), host),
        )
        assertEquals(
            DictationToastSpec(R.string.voice_dictation_recording_unavailable, GlobalToastStyle.Error, 3_000L),
            dictationToast(DictationEvent.RecordingUnavailable(host), host),
        )
    }

    @Test
    fun `other slot events show no toast`() {
        assertNull(dictationToast(DictationEvent.NoSpeech(other), host))
        assertNull(dictationToast(DictationEvent.DiscardUndoable(other), host))
        assertNull(dictationToast(DictationEvent.RecordingUnavailable(other), host))
    }

    @Test
    fun `undo action maps to undo`() {
        val onUndo: () -> Unit = {}
        val spec = dictationToast(DictationEvent.DiscardUndoable(host), host)!!
        assertEquals(
            GlobalToastAction(UiText.Resource(R.string.voice_dictation_undo), onUndo),
            spec.snackbarAction(onUndo),
        )
    }

    @Test
    fun `voice settings action maps to open`() {
        val open: () -> Unit = {}
        val spec = dictationToast(DictationEvent.SystemUnavailable(host), host)!!
        assertEquals(
            GlobalToastAction(UiText.Resource(R.string.voice_settings_action), open),
            spec.snackbarAction(open),
        )
    }

    @Test
    fun `no action no button`() {
        val spec = dictationToast(DictationEvent.RecordingUnavailable(host), host)!!
        assertNull(spec.snackbarAction {})
        assertNull(dictationToast(DictationEvent.SystemUnavailable(host), host)!!.snackbarAction(null))
    }
}
