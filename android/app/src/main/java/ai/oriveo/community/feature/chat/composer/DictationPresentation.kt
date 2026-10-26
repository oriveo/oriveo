package ai.oriveo.community.feature.chat.composer

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationEvent
import ai.oriveo.community.core.voice.DictationFailedAction
import ai.oriveo.community.core.voice.DictationState
import kotlin.math.floor

/**
 * Pure presentation rules for dictation: controller state / events
 * map to the status card, the input row shape, duration text and toast specs. No Koin, no Compose;
 * texts are string resources plus format arguments, resolved by the view.
 */

/** A string resource with its format arguments. */
data class DictationText(@param:StringRes val res: Int, val args: List<Any> = emptyList())

/** Card button intents; the host executes them. */
enum class DictationCardAction {
    Discard,
    Retry,
    CheckConnection,
    TranscribeRecording,
    TranscribeFirst,
    DiscardAndRerecord,
    NotNow,
    OpenSettings,
}

data class DictationCardButton(@param:StringRes val label: Int, val action: DictationCardAction)

/** Leading status icon of a card: Error = red exclamation circle, Waveform = brand waveform. */
enum class DictationCardIcon { Error, Waveform }

data class DictationCard(
    @param:StringRes val title: Int,
    val subtitle: DictationText,
    val secondary: DictationCardButton,
    val primary: DictationCardButton,
    /** Null = no leading icon. */
    val icon: DictationCardIcon? = null,
)

/** Input row shape for a host slot. */
sealed interface DictationInputRow {
    data object Normal : DictationInputRow

    data class Recording(val startedAt: Long) : DictationInputRow

    data class Busy(val label: DictationText) : DictationInputRow
}

data class DictationToastSpec(
    @param:StringRes val message: Int,
    val style: GlobalToastStyle,
    val durationMillis: Long,
    /** Non-null for the undo toast: the label is [undoLabel], tapping it calls undoDiscard(slotKey). */
    val undoSlotKey: String? = null,
    @param:StringRes val undoLabel: Int? = null,
    /** Non-null for toasts with a host action button: the label is [actionLabel], tapping it runs [action]. */
    @param:StringRes val actionLabel: Int? = null,
    val action: DictationToastAction? = null,
)

/**
 * Snackbar button for this toast: the undo label wins, otherwise the host action label.
 * [onAction] is the callback the coordinator passed to showToast; no callback or no label means no button.
 */
fun DictationToastSpec.snackbarAction(onAction: (() -> Unit)?): GlobalToastAction? {
    val label = undoLabel ?: actionLabel
    return if (onAction != null && label != null) GlobalToastAction(UiText.Resource(label), onAction) else null
}

/** Host action behind a toast button. */
enum class DictationToastAction { OpenVoiceSettings }

const val DICTATION_TOAST_DEFAULT_MILLIS = 3_000L
const val DICTATION_TOAST_UNDO_MILLIS = 4_000L
const val DICTATION_TOAST_SYSTEM_UNAVAILABLE_MILLIS = 6_000L

/**
 * Status card for the host slot, or null. Cards show only when the state's slotKey equals
 * [hostSlotKey]; Denied carries no slot and shows only on the currently bound host.
 * [pendingDurationSec] is the saved recording length; null falls back to "recording saved".
 */
fun dictationCard(
    state: DictationState,
    hostSlotKey: String,
    isBoundHost: Boolean,
    pendingDurationSec: Double?,
): DictationCard? {
    val discard = DictationCardButton(R.string.voice_dictation_discard, DictationCardAction.Discard)
    val saved = DictationText(R.string.voice_dictation_recording_saved)
    val savedDuration =
        pendingDurationSec?.let {
            DictationText(R.string.voice_dictation_saved_duration, listOf(formatDictationDuration(it)))
        } ?: saved
    return when (state) {
        DictationState.Denied ->
            if (!isBoundHost) {
                null
            } else {
                DictationCard(
                    title = R.string.voice_dictation_mic_denied_title,
                    subtitle = DictationText(R.string.voice_dictation_denied_subtitle),
                    secondary = DictationCardButton(R.string.voice_dictation_not_now, DictationCardAction.NotNow),
                    primary = DictationCardButton(R.string.voice_dictation_open_settings, DictationCardAction.OpenSettings),
                    icon = DictationCardIcon.Error,
                )
            }
        is DictationState.Failed ->
            if (state.slotKey != hostSlotKey) {
                null
            } else {
                when (state.action) {
                    DictationFailedAction.Retry ->
                        DictationCard(
                            title = R.string.voice_dictation_failed_title,
                            subtitle = saved,
                            secondary = discard,
                            primary = DictationCardButton(R.string.voice_dictation_retry, DictationCardAction.Retry),
                            icon = DictationCardIcon.Error,
                        )
                    DictationFailedAction.CheckConnection ->
                        DictationCard(
                            title = R.string.voice_dictation_failed_title,
                            subtitle = DictationText(R.string.voice_dictation_connection_unavailable),
                            secondary = discard,
                            primary =
                                DictationCardButton(
                                    R.string.voice_dictation_check_connection,
                                    DictationCardAction.CheckConnection,
                                ),
                            icon = DictationCardIcon.Error,
                        )
                    DictationFailedAction.NoTranscript ->
                        DictationCard(
                            title = R.string.voice_dictation_no_text,
                            subtitle = saved,
                            secondary = discard,
                            primary = DictationCardButton(R.string.voice_dictation_retry, DictationCardAction.Retry),
                            icon = DictationCardIcon.Error,
                        )
                }
            }
        is DictationState.Interrupted ->
            if (state.slotKey != hostSlotKey) {
                null
            } else {
                DictationCard(
                    title = R.string.voice_dictation_interrupted,
                    subtitle = savedDuration,
                    secondary = discard,
                    primary =
                        DictationCardButton(
                            R.string.voice_dictation_transcribe_recording,
                            DictationCardAction.TranscribeRecording,
                        ),
                    icon = DictationCardIcon.Waveform,
                )
            }
        is DictationState.SlotOccupied ->
            if (state.slotKey != hostSlotKey) {
                null
            } else {
                DictationCard(
                    title = R.string.voice_dictation_slot_occupied,
                    subtitle = savedDuration,
                    secondary =
                        DictationCardButton(
                            R.string.voice_dictation_discard_and_rerecord,
                            DictationCardAction.DiscardAndRerecord,
                        ),
                    primary =
                        DictationCardButton(R.string.voice_dictation_transcribe_first, DictationCardAction.TranscribeFirst),
                    icon = DictationCardIcon.Waveform,
                )
            }
        DictationState.Idle, is DictationState.Recording, is DictationState.Transcribing -> null
    }
}

/** Input row for the host slot: recording bar, busy (transcribing) or normal. */
fun dictationInputRow(
    state: DictationState,
    hostSlotKey: String,
    engineInfo: DictationEngineInfo,
): DictationInputRow =
    when {
        state is DictationState.Recording && state.slotKey == hostSlotKey ->
            DictationInputRow.Recording(state.startedAt)
        state is DictationState.Transcribing && state.slotKey == hostSlotKey -> {
            val name = engineInfo.displayName?.takeIf { engineInfo.isCloud && it.isNotBlank() }
            DictationInputRow.Busy(
                if (name != null) {
                    DictationText(R.string.voice_dictation_transcribing_with, listOf(name))
                } else {
                    DictationText(R.string.voice_dictation_transcribing)
                },
            )
        }
        else -> DictationInputRow.Normal
    }

/** Floors to whole seconds; m:ss below one hour, h:mm:ss from one hour. */
fun formatDictationDuration(seconds: Double): String {
    val total = if (seconds.isNaN() || seconds <= 0.0) 0L else floor(seconds).toLong()
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    val ss = s.toString().padStart(2, '0')
    return if (h > 0) "$h:${m.toString().padStart(2, '0')}:$ss" else "$m:$ss"
}

/** Toast for an event of the host slot; null for other slots and for Insert / Send (no toast). */
fun dictationToast(
    event: DictationEvent,
    hostSlotKey: String,
): DictationToastSpec? {
    val slotKey =
        when (event) {
            is DictationEvent.Insert -> event.slotKey
            is DictationEvent.Send -> event.slotKey
            is DictationEvent.NoSpeech -> event.slotKey
            is DictationEvent.RecordingUnavailable -> event.slotKey
            is DictationEvent.DiscardUndoable -> event.slotKey
            is DictationEvent.EngineFallback -> event.slotKey
            is DictationEvent.SystemUnavailable -> event.slotKey
            is DictationEvent.SystemRecognizerFailed -> event.slotKey
        }
    if (slotKey != hostSlotKey) return null
    return when (event) {
        is DictationEvent.Insert, is DictationEvent.Send -> null
        is DictationEvent.NoSpeech ->
            DictationToastSpec(R.string.voice_dictation_no_speech, GlobalToastStyle.Info, DICTATION_TOAST_DEFAULT_MILLIS)
        is DictationEvent.EngineFallback ->
            DictationToastSpec(R.string.voice_dictation_engine_fallback, GlobalToastStyle.Info, DICTATION_TOAST_DEFAULT_MILLIS)
        is DictationEvent.DiscardUndoable ->
            DictationToastSpec(
                message = R.string.voice_dictation_discarded,
                style = GlobalToastStyle.Removed,
                durationMillis = DICTATION_TOAST_UNDO_MILLIS,
                undoSlotKey = event.slotKey,
                undoLabel = R.string.voice_dictation_undo,
            )
        is DictationEvent.SystemUnavailable ->
            DictationToastSpec(
                message = R.string.voice_dictation_system_unavailable,
                style = GlobalToastStyle.Warning,
                durationMillis = DICTATION_TOAST_SYSTEM_UNAVAILABLE_MILLIS,
                actionLabel = R.string.voice_settings_action,
                action = DictationToastAction.OpenVoiceSettings,
            )
        is DictationEvent.SystemRecognizerFailed ->
            DictationToastSpec(
                R.string.voice_dictation_recognizer_failed,
                GlobalToastStyle.Warning,
                DICTATION_TOAST_DEFAULT_MILLIS,
            )
        is DictationEvent.RecordingUnavailable ->
            DictationToastSpec(
                R.string.voice_dictation_recording_unavailable,
                GlobalToastStyle.Error,
                DICTATION_TOAST_DEFAULT_MILLIS,
            )
    }
}
