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
import java.util.Locale
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
    /** Opens voice settings (no deep link to the language sheet). */
    ChangeLanguage,
    /** Opens voice settings (no deep link to the engine sheet). */
    SwitchEngine,
}

data class DictationCardButton(@param:StringRes val label: Int, val action: DictationCardAction)

/** Leading status icon of a card: Error = red exclamation circle, Waveform = brand waveform. */
enum class DictationCardIcon { Error, Waveform }

data class DictationCard(
    val title: DictationText,
    /** Null = no body text. */
    val subtitle: DictationText?,
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
    /** Format arguments of [message]. */
    val messageArgs: List<String> = emptyList(),
)

/** Snackbar text for this toast: [DictationToastSpec.message] formatted with its arguments. */
fun DictationToastSpec.snackbarText(): UiText = UiText.Resource(message, messageArgs)

/**
 * Snackbar button for this toast: the undo label wins, otherwise the host action label.
 * [onAction] is the callback the coordinator passed to showToast; no callback or no label means no button.
 */
fun DictationToastSpec.snackbarAction(onAction: (() -> Unit)?): GlobalToastAction? {
    val label = undoLabel ?: actionLabel
    return if (onAction != null && label != null) GlobalToastAction(UiText.Resource(label), onAction) else null
}

/** Host action behind a toast button. */
enum class DictationToastAction { OpenVoiceSettings, DownloadLanguagePack }

const val DICTATION_TOAST_DEFAULT_MILLIS = 3_000L
const val DICTATION_TOAST_UNDO_MILLIS = 4_000L
const val DICTATION_TOAST_SYSTEM_UNAVAILABLE_MILLIS = 6_000L
const val DICTATION_TOAST_LANGUAGE_PACK_MILLIS = 6_000L

/** Language pack prompt (E-257): names the recognition language and offers a Download button. */
fun languagePackOfferToast(languageName: String): DictationToastSpec =
    DictationToastSpec(
        message = R.string.voice_language_pack_prompt,
        style = GlobalToastStyle.Info,
        durationMillis = DICTATION_TOAST_LANGUAGE_PACK_MILLIS,
        actionLabel = R.string.voice_language_pack_download,
        action = DictationToastAction.DownloadLanguagePack,
        messageArgs = listOf(languageName),
    )

/** Shown after the user accepts the language pack prompt; no button. */
fun languagePackDownloadingToast(languageName: String): DictationToastSpec =
    DictationToastSpec(
        message = R.string.voice_language_pack_downloading,
        style = GlobalToastStyle.Info,
        durationMillis = DICTATION_TOAST_LANGUAGE_PACK_MILLIS,
        messageArgs = listOf(languageName),
    )

/**
 * Status card for the host slot, or null. Cards show only when the state's slotKey equals
 * [hostSlotKey]; Denied carries no slot and shows only on the currently bound host.
 * [pendingDurationSec] is the saved recording length; null falls back to "recording saved".
 * [uiLocale] is the app UI locale; the recognition language is named in it.
 */
fun dictationCard(
    state: DictationState,
    hostSlotKey: String,
    isBoundHost: Boolean,
    pendingDurationSec: Double?,
    uiLocale: Locale = Locale.getDefault(),
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
                    title = DictationText(R.string.voice_dictation_mic_denied_title),
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
                failedCard(state, discard, saved, uiLocale)
            }
        is DictationState.Interrupted ->
            if (state.slotKey != hostSlotKey) {
                null
            } else {
                DictationCard(
                    title = DictationText(R.string.voice_dictation_interrupted),
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
                    title = DictationText(R.string.voice_dictation_slot_occupied),
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

/**
 * Failed card per failure reason (E-252): real cause in title and body, matching primary action.
 * Without a recording (self-record failure) the title stays, the body is dropped (every body says the
 * recording is saved) and the actions become discard / retry (a new dictation).
 */
private fun failedCard(
    state: DictationState.Failed,
    discard: DictationCardButton,
    saved: DictationText,
    uiLocale: Locale,
): DictationCard {
    val card = failedCardWithRecording(state, discard, saved, uiLocale)
    if (state.hasRecording) return card
    return card.copy(
        subtitle = null,
        secondary = discard,
        // Labelled "Retry" but starts a new dictation; "Discard and Re-record" is only for a saved recording.
        primary = DictationCardButton(R.string.voice_dictation_retry, DictationCardAction.DiscardAndRerecord),
    )
}

private fun failedCardWithRecording(
    state: DictationState.Failed,
    discard: DictationCardButton,
    saved: DictationText,
    uiLocale: Locale,
): DictationCard {
    val retry = DictationCardButton(R.string.voice_dictation_retry, DictationCardAction.Retry)
    val changeLanguage =
        DictationCardButton(R.string.voice_dictation_action_change_language, DictationCardAction.ChangeLanguage)
    fun card(title: DictationText, subtitle: DictationText, secondary: DictationCardButton, primary: DictationCardButton) =
        DictationCard(title, subtitle, secondary, primary, DictationCardIcon.Error)
    return when (state.action) {
        DictationFailedAction.Retry ->
            card(DictationText(R.string.voice_dictation_failed_title), saved, discard, retry)
        DictationFailedAction.CheckConnection ->
            card(
                DictationText(R.string.voice_dictation_failed_title),
                DictationText(R.string.voice_dictation_connection_unavailable),
                discard,
                DictationCardButton(R.string.voice_dictation_check_connection, DictationCardAction.CheckConnection),
            )
        DictationFailedAction.NoTranscript ->
            card(
                DictationText(R.string.voice_dictation_no_text),
                DictationText(R.string.voice_dictation_no_text_body, listOf(languageName(state.language, uiLocale))),
                retry,
                changeLanguage,
            )
        DictationFailedAction.Network ->
            card(
                DictationText(R.string.voice_dictation_fail_network_title),
                DictationText(R.string.voice_dictation_fail_network_body),
                discard,
                retry,
            )
        DictationFailedAction.Busy ->
            card(
                DictationText(R.string.voice_dictation_fail_busy_title),
                DictationText(R.string.voice_dictation_fail_busy_body),
                discard,
                retry,
            )
        DictationFailedAction.LanguageUnsupported ->
            card(
                DictationText(R.string.voice_dictation_fail_language_title, listOf(languageName(state.language, uiLocale))),
                DictationText(R.string.voice_dictation_fail_language_body),
                discard,
                changeLanguage,
            )
        DictationFailedAction.NoService ->
            card(
                DictationText(R.string.voice_dictation_fail_no_service_title),
                DictationText(R.string.voice_dictation_fail_no_service_body),
                discard,
                DictationCardButton(R.string.voice_dictation_action_switch_engine, DictationCardAction.SwitchEngine),
            )
    }
}

/**
 * Recognition language [tag] named in [uiLocale]; no tag means "auto", which recognizes in the UI language
 * (same as the dictation environment).
 */
internal fun languageName(tag: String?, uiLocale: Locale): String {
    val locale = tag?.takeIf { it.isNotBlank() }?.let(Locale::forLanguageTag) ?: uiLocale
    return locale.getDisplayName(uiLocale)
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
            is DictationEvent.LiveRetract -> event.slotKey
            // Not tied to a slot; the language pack prompt is not a toast.
            is DictationEvent.LanguagePackOffer -> return null
        }
    if (slotKey != hostSlotKey) return null
    return when (event) {
        is DictationEvent.Insert, is DictationEvent.Send, is DictationEvent.LiveRetract,
        is DictationEvent.LanguagePackOffer,
        -> null
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
        is DictationEvent.RecordingUnavailable ->
            DictationToastSpec(
                R.string.voice_dictation_recording_unavailable,
                GlobalToastStyle.Error,
                DICTATION_TOAST_DEFAULT_MILLIS,
            )
    }
}
