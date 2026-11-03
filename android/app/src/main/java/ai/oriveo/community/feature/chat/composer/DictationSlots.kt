package ai.oriveo.community.feature.chat.composer

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.feature.chat.voice.RecognitionLanguageSheet
import ai.oriveo.community.ui.component.isReduceMotionEnabled

/**
 * The only two composables that observe the dictation controller (host and text field do not).
 * Shared by the chat page and the home composer; both take the handle from [rememberDictationHost].
 */

/**
 * Input row switcher: recording bar while this slot records, busy row
 * while this slot transcribes, otherwise [normal]. A null [handle] (no controller) renders only [normal].
 * [canSend] gives the outer ↑ the same availability as the host send button.
 *
 * With [input], the text field stays on screen while recording / transcribing (live dictation is written into
 * it): [input] is laid out above the switched row in a column and only [normal] is replaced. Like iOS
 * DictationInputRow, the recording bar / busy row is a row of its own [spacing] below [input] (outside the
 * caller's input frame); [normal] follows [input] directly, so an empty [normal] leaves no gap.
 * [input] gets the current row so it can drop its own buttons and show the listening placeholder.
 */
@Composable
fun DictationInputSwitcher(
    handle: DictationHostCoordinator?,
    canSend: () -> Boolean,
    modifier: Modifier = Modifier,
    spacing: Dp = 0.dp,
    input: (@Composable (row: DictationInputRow) -> Unit)? = null,
    normal: @Composable () -> Unit,
) {
    if (handle == null) {
        if (input == null) {
            normal()
        } else {
            Column(modifier = modifier) {
                input(DictationInputRow.Normal)
                normal()
            }
        }
        return
    }
    val commands = handle.commands
    val state by commands.state.collectAsStateWithLifecycle()
    val engineInfo by commands.engineInfo.collectAsStateWithLifecycle()
    val row = dictationInputRow(state, handle.hostSlotKey, engineInfo ?: DictationEngineInfo.System)
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    val rowModifier = if (input == null) modifier else Modifier.fillMaxWidth().padding(top = spacing)
    val content: @Composable (DictationInputRow) -> Unit = { shown ->
        when (shown) {
            DictationInputRow.Normal -> normal()
            is DictationInputRow.Recording ->
                ComposerDictationBar(
                    startedAt = shown.startedAt,
                    levels = commands.levelMeter,
                    canSend = canSend(),
                    onDiscard = commands::discard,
                    onTranscribe = { commands.finish(DictationSubmit.Insert) },
                    onTranscribeAndSend = { commands.finish(DictationSubmit.Send) },
                    modifier = rowModifier,
                )
            is DictationInputRow.Busy ->
                ComposerDictationBusyRow(
                    label = shown.label,
                    onCancel = commands::discard,
                    modifier = rowModifier,
                )
        }
    }
    // The three row shapes cross-fade; with system animations reduced they switch directly.
    val switched: @Composable () -> Unit = {
        if (reduceMotion) {
            content(row)
        } else {
            Crossfade(targetState = row, label = "dictation-input-row") { shown -> content(shown) }
        }
    }
    if (input == null) {
        switched()
    } else {
        Column(modifier = modifier) {
            input(row)
            switched()
        }
    }
}

/**
 * Main key slot beside the input row: hidden while [DictationInputSwitcher] shows the recording bar or the
 * busy row for this slot (the bar carries its own ↑), matching iOS. Cards and idle keep [mainKey].
 * Uses the switcher's cross-fade; with system animations reduced it switches directly. A null [handle]
 * renders only [mainKey].
 */
@Composable
fun DictationMainKeySlot(
    handle: DictationHostCoordinator?,
    mainKey: @Composable () -> Unit,
) {
    if (handle == null) {
        mainKey()
        return
    }
    val commands = handle.commands
    val state by commands.state.collectAsStateWithLifecycle()
    val engineInfo by commands.engineInfo.collectAsStateWithLifecycle()
    val visible = dictationInputRow(state, handle.hostSlotKey, engineInfo ?: DictationEngineInfo.System) ==
        DictationInputRow.Normal
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    if (reduceMotion) {
        if (visible) mainKey()
    } else {
        Crossfade(targetState = visible, label = "dictation-main-key") { shown -> if (shown) mainKey() }
    }
}

/**
 * Status card slot: shows the card for this host slot, if any, and
 * routes its buttons through the coordinator. Only the handle whose owner is the controller's bound owner
 * counts as the bound host (Denied shows only there). A null [handle] renders nothing.
 * "Change recognition language" opens [RecognitionLanguageSheet] on the current page (home and chat both come
 * through here); [languageSettings] overrides the sheet's settings (null = the Koin instance).
 */
@Composable
fun DictationPromptSlot(
    handle: DictationHostCoordinator?,
    modifier: Modifier = Modifier,
    languageSettings: VoiceEngineSettings? = null,
) {
    if (handle == null) return
    val commands = handle.commands
    val languagePickerOpen by handle.languagePickerOpen.collectAsStateWithLifecycle()
    if (languagePickerOpen) {
        if (languageSettings == null) {
            RecognitionLanguageSheet(onDismiss = handle::closeLanguagePicker)
        } else {
            RecognitionLanguageSheet(onDismiss = handle::closeLanguagePicker, settings = languageSettings)
        }
    }
    val state by commands.state.collectAsStateWithLifecycle()
    val pendingDurationSec by commands.pendingDurationSec.collectAsStateWithLifecycle()
    val boundOwner by commands.boundOwner.collectAsStateWithLifecycle()
    val card =
        dictationCard(
            state = state,
            hostSlotKey = handle.hostSlotKey,
            isBoundHost = boundOwner === handle.owner,
            pendingDurationSec = pendingDurationSec,
            uiLocale = LocalConfiguration.current.locales[0],
        ) ?: return
    DictationPromptCard(
        card = card,
        onSecondary = { handle.onCardAction(card.secondary.action) },
        onPrimary = { handle.onCardAction(card.primary.action) },
        modifier = modifier,
    )
}
