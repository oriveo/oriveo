package ai.oriveo.community.feature.chat.voice

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * The chat composer while the conversation's model is a realtime voice model (card V1), in the same panel as the ≋
 * stage (E-526, E-256): the stage orb at rest ([VoiceAuroraOrbSize]) with "tap to start talking" under it and a
 * "Switch to Typing" chip centered in the bottom row (PM0 card A3), on the stage buttons' center line. No attachments,
 * tools or dictation, and no mute / end: those exist only on the voice stage, once a session runs (the switcher fades
 * this dock out and scales them in). Tapping the orb starts the session.
 */
@Composable
internal fun RealtimeVoiceDock(
    onStart: () -> Unit,
    onKeyboard: () -> Unit,
    modifier: Modifier = Modifier,
    /** false where the dock does not sit at the screen bottom (the home hero card). */
    navigationBarInset: Boolean = true,
    /** Centered above the orb (the home page's model pill, PM0 card A3); null = none (the chat page). */
    header: (@Composable () -> Unit)? = null,
    /**
     * The home pill holds a realtime model but the voice catalog has not arrived yet (PM1 card A2): same layout,
     * the orb does not respond and the status line reads "Loading"; the keyboard chip still works.
     */
    preparing: Boolean = false,
    /**
     * While [preparing]: the voice catalog failed to load (PM1 card A2c, E-762). The caption slot shows the failure
     * card with a single "Retry" action ([onRetryCatalog]), disabled while [catalogRetrying].
     */
    catalogFailed: Boolean = false,
    catalogRetrying: Boolean = false,
    onRetryCatalog: () -> Unit = {},
) {
    val label = if (preparing) R.string.local_model_loading else R.string.voice_realtime_tap_to_start
    val prompt = stringResource(label)
    // PM1 card A4: a session that ended on a failure returns here with its card (not while the catalog loads).
    val idleFailure = LocalRealtimeIdleFailure.current?.takeIf { !preparing }
    val failureCard = realtimeIdleFailureCard(idleFailure?.failure)
    // After max_duration the orb continues the call with the history (as on iOS).
    val startTap: () -> Unit = if (idleFailure != null && realtimeFailureContinuesOnTap(idleFailure.failure)) {
        { idleFailure.onAction(RealtimeFailureAction.ContinueWithHistory) }
    } else {
        onStart
    }
    VoiceStagePanel(
        mode = VoiceOrbMode.Idle,
        level = null,
        notice = false,
        modifier = modifier.then(if (navigationBarInset) Modifier.navigationBarsPadding() else Modifier),
        header = header,
    ) { buttonBottom ->
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = StageOrbTop)
                .size(VoiceAuroraOrbSize)
                // No clip and no ripple: the orb's glow spills past its circle (same as the stage orb).
                .then(
                    if (preparing) {
                        Modifier.clearAndSetSemantics {
                            contentDescription = prompt
                            testTag = RealtimeVoiceDockOrbTag
                        }
                    } else {
                        Modifier
                            .clickable(interactionSource = null, indication = null, onClick = startTap)
                            .clearAndSetSemantics {
                                contentDescription = prompt
                                testTag = RealtimeVoiceDockOrbTag
                                role = Role.Button
                                onClick {
                                    startTap()
                                    true
                                }
                            }
                    },
                ),
        ) {
            VoiceAuroraOrb(mode = VoiceOrbMode.Idle, level = null, nudges = 0)
        }
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .padding(top = StageOrbTop + VoiceAuroraOrbSize + StageCaptionGap)
                // Reserves the button row so taller words push the panel up, not into the button.
                .padding(bottom = buttonBottom + StageButtonSize + StageChipGap),
        ) {
            if (preparing && catalogFailed) {
                // Catalog failed to load (E-762): only "Retry", same refresh as the chat page's row; no open-connection.
                RealtimeFailureCard(
                    model = CatalogFailureCard,
                    onAction = { if (!catalogRetrying) onRetryCatalog() },
                    enabled = !catalogRetrying,
                    // The card spans nearly the stage width, like the stage's own failure card.
                    modifier = Modifier.padding(horizontal = DockCardInset),
                )
            } else if (failureCard != null && idleFailure != null) {
                RealtimeFailureCard(
                    model = failureCard,
                    onAction = idleFailure.onAction,
                    modifier = Modifier.padding(horizontal = DockCardInset),
                )
            } else {
                Box(Modifier.padding(horizontal = StageCaptionInset)) {
                    // Read on the orb node instead, so it is spoken once.
                    StatusWord(label = label, notice = false, onLayout = {})
                }
            }
        }
        // A button-tall row at the stage buttons' bottom: the chip sits on their center line.
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = buttonBottom)
                .height(StageButtonSize),
            contentAlignment = Alignment.Center,
        ) {
            KeyboardChip(onClick = onKeyboard)
        }
    }
}

/** Same side inset as the stage's failure card. */
private val DockCardInset = 16.dp

/** The dock's catalog failure card: the catalog-unavailable copy and a single "Retry" (PM1 card A2c). */
private val CatalogFailureCard = RealtimeFailureCardModel(
    category = RealtimeModel.CATEGORY_NETWORK,
    title = R.string.voice_realtime_catalog_unavailable,
    titleArgs = emptyList(),
    buttons = listOf(RealtimeFailureButton(RealtimeFailureAction.Retry, R.string.voice_realtime_action_retry)),
)

internal const val RealtimeVoiceDockOrbTag = "realtime_voice_dock_orb_button"
internal const val RealtimeVoiceDockKeyboardTag = "realtime_voice_dock_keyboard_button"

private val KeyboardChipHeight = 36.dp

/**
 * "Switch to Typing" chip: 36 dp glass capsule (same glass and 0.5 dp hairline as the stage's mute button when off),
 * keyboard glyph + label in the stage purple, shaped like the check-language chip. Its touch target reaches 48 dp
 * through Compose's minimum touch target expansion around pointer input smaller than that.
 */
@Composable
private fun KeyboardChip(onClick: () -> Unit) {
    val dark = OriveoTheme.isDark
    val content = stageButtonBrand(dark)
    // The glyph grows with the system text size, like the label beside it.
    val glyph = 15.dp * LocalDensity.current.fontScale
    Row(
        modifier = Modifier
            .heightIn(min = KeyboardChipHeight)
            .then(stageGlassFill(dark))
            .clip(CircleShape)
            .testTag(RealtimeVoiceDockKeyboardTag)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painter = painterResource(VoiceGlyphs.keyboard),
            contentDescription = null,
            tint = content,
            modifier = Modifier.size(glyph),
        )
        Text(
            text = stringResource(R.string.voice_realtime_switch_to_keyboard),
            style = OriveoTheme.typography.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold, color = content),
            maxLines = 1,
        )
    }
}
