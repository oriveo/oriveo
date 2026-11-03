package ai.oriveo.community.feature.chat.voice

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.RelayModelFallback
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * A realtime session that ended on one of the six failure categories: [category] is a
 * [RealtimeModel.CATEGORIES] name; [providerId] / [providerName] / [model] fill the copy placeholder and the
 * open-connection action.
 */
data class RealtimeFailure(
    val category: String,
    val providerId: String,
    val providerName: String,
    val model: String,
)

/** Connection and model a realtime failure names. */
internal data class RealtimeFailureSubject(val providerId: String, val providerName: String, val model: String)

/** Ways out of a failure (RealtimeModel.ACTIONS). */
enum class RealtimeFailureAction(val rawValue: String) {
    OpenConnection(RealtimeModel.ACTION_OPEN_CONNECTION),
    Retry(RealtimeModel.ACTION_RETRY),
    SwitchModel(RealtimeModel.ACTION_SWITCH_MODEL),
    ContinueWithHistory(RealtimeModel.ACTION_CONTINUE_WITH_HISTORY),
    ;

    companion object {
        fun fromRawValue(raw: String): RealtimeFailureAction? = entries.firstOrNull { it.rawValue == raw }
    }
}

/** One button of the failure card: [label] is a string resource. */
internal data class RealtimeFailureButton(val action: RealtimeFailureAction, @StringRes val label: Int)

/**
 * What the stage shows for a failure: the card's [title] (with [titleArgs]) and its [buttons], the first one primary.
 * max_duration has no card (null [buttons] never happens; see [realtimeFailureCard]).
 */
internal data class RealtimeFailureCardModel(
    val category: String,
    @StringRes val title: Int,
    val titleArgs: List<Any>,
    val buttons: List<RealtimeFailureButton>,
)

/** Fixture copy key → string resource (RealtimeModel copy keys stay strings in the pure layer). */
@StringRes
internal fun realtimeCopyRes(key: String): Int? = when (key) {
    "voice_realtime_failure_auth" -> R.string.voice_realtime_failure_auth
    "voice_realtime_failure_quota" -> R.string.voice_realtime_failure_quota
    "voice_realtime_failure_model_gone" -> R.string.voice_realtime_failure_model_gone
    "voice_realtime_failure_max_duration" -> R.string.voice_realtime_failure_max_duration
    "voice_realtime_failure_network" -> R.string.voice_realtime_failure_network
    "voice_realtime_failure_unknown" -> R.string.voice_realtime_failure_unknown
    "voice_realtime_action_open_connection" -> R.string.voice_realtime_action_open_connection
    "voice_realtime_action_retry" -> R.string.voice_realtime_action_retry
    "voice_realtime_action_switch_model" -> R.string.voice_realtime_action_switch_model
    else -> null
}

private fun category(failure: RealtimeFailure): String =
    failure.category.takeIf { it in RealtimeModel.CATEGORIES } ?: RealtimeModel.CATEGORY_UNKNOWN

/** The failure ends the call on the stage itself: tapping the orb starts a new call with the history (max_duration). */
internal fun realtimeFailureContinuesOnTap(failure: RealtimeFailure?): Boolean =
    failure != null && category(failure) == RealtimeModel.CATEGORY_MAX_DURATION

/**
 * The failure card of [failure]; null = no card (no failure, or max_duration: the status word turns into
 * [realtimeFailureStatusWord] and the orb tap continues).
 */
internal fun realtimeFailureCard(failure: RealtimeFailure?): RealtimeFailureCardModel? {
    if (failure == null || realtimeFailureContinuesOnTap(failure)) return null
    val category = category(failure)
    val actions = RealtimeModel.ACTIONS.getValue(category)
    val args: List<Any> = when (RealtimeModel.COPY_FAILURE_ARG.getValue(category)) {
        "provider" -> listOf(failure.providerName)
        "model" -> listOf(failure.model)
        else -> emptyList()
    }
    return RealtimeFailureCardModel(
        category = category,
        title = realtimeCopyRes(RealtimeModel.COPY_FAILURE.getValue(category))!!,
        titleArgs = args,
        buttons = actions.mapNotNull { raw ->
            val action = RealtimeFailureAction.fromRawValue(raw) ?: return@mapNotNull null
            val label = RealtimeModel.COPY_ACTIONS[raw]?.let(::realtimeCopyRes) ?: return@mapNotNull null
            RealtimeFailureButton(action, label)
        },
    )
}

/**
 * The card the idle stage shows for [failure] (PM1 card A4, as iOS RealtimeIdleStageSurface): the category card, or for
 * max_duration a card with only its copy and no actions (tapping the orb continues). null = no failure.
 */
internal fun realtimeIdleFailureCard(failure: RealtimeFailure?): RealtimeFailureCardModel? {
    realtimeFailureCard(failure)?.let { return it }
    val word = realtimeFailureStatusWord(failure) ?: return null
    return RealtimeFailureCardModel(
        category = RealtimeModel.CATEGORY_MAX_DURATION,
        title = word,
        titleArgs = emptyList(),
        buttons = emptyList(),
    )
}

/** A realtime failure handed to the idle stage with its way out ([onAction], the handle's perform). */
internal class RealtimeIdleFailure(val failure: RealtimeFailure, val onAction: (RealtimeFailureAction) -> Unit)

/** Set by [VoiceConversationSwitcher] around the page's idle content; read by [RealtimeVoiceDock]. */
internal val LocalRealtimeIdleFailure = compositionLocalOf<RealtimeIdleFailure?> { null }

/** Status word in place of the card: only max_duration ("reached the limit, tap to continue"); null = none. */
@StringRes
internal fun realtimeFailureStatusWord(failure: RealtimeFailure?): Int? =
    if (realtimeFailureContinuesOnTap(failure)) {
        realtimeCopyRes(RealtimeModel.COPY_FAILURE.getValue(RealtimeModel.CATEGORY_MAX_DURATION))
    } else {
        null
    }

/**
 * What the screen reader speaks for the stage: a realtime failure's own copy (card title with its placeholder, or the
 * max_duration word) instead of the generic error word; otherwise the status word. null = nothing.
 */
internal fun voiceStatusAnnouncement(status: ConversationStatusKey?, failure: RealtimeFailure?): Pair<Int, List<Any>>? {
    realtimeFailureCard(failure)?.let { return it.title to it.titleArgs }
    realtimeFailureStatusWord(failure)?.let { return it to emptyList() }
    return status?.let { VoiceConversationBarStatus.label(it) to emptyList() }
}

/** "Switch Model" after model_gone first returns the selection to the last text model (design §6.6). */
internal fun realtimeFailureRestoresTextModel(failure: RealtimeFailure?): Boolean =
    failure != null && category(failure) == RealtimeModel.CATEGORY_MODEL_GONE

/**
 * The last used text model to return to before the picker opens; null = none or no longer usable (its connection is
 * gone, the model retired or removed from the relay): the picker opens without changing the selection. Realtime
 * models are never written as last used, so a valid [lastUsed] is always a text model.
 */
internal fun lastTextModelToRestore(providers: List<Provider>, lastUsed: LastUsedModelRef?): LastUsedModelRef? {
    val ref = lastUsed?.takeIf { it.providerID.isNotBlank() && it.modelID.isNotBlank() } ?: return null
    val provider = providers.firstOrNull { it.id == ref.providerID } ?: return null
    if (ProviderSelectionSnapshot.modelRetirement(provider, ref.modelID)?.sendBlocked == true) return null
    if (RelayModelFallback.removedConnectionName(provider, ref.modelID) != null) return null
    return ref
}

private val CardShape = RoundedCornerShape(24.dp)
private val ButtonHeight = 40.dp

/**
 * Failure card in the stage's caption slot: 24 dp floating card (hairline border, 0/14/34 α.10 shadow), a 40 dp amber
 * gradient disc with the waveform, the category copy, then the secondary (gray capsule) and primary (brand gradient
 * capsule) actions, both 40 dp tall. Colors come from theme tokens.
 */
@Composable
internal fun RealtimeFailureCard(
    model: RealtimeFailureCardModel,
    onAction: (RealtimeFailureAction) -> Unit,
    modifier: Modifier = Modifier,
    /** false = the actions are disabled (a retry already running, PM1 card A2c). */
    enabled: Boolean = true,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .dropShadow(
                shape = CardShape,
                shadow = Shadow(
                    radius = 34.dp,
                    color = colors.shadow.copy(alpha = 0.10f),
                    offset = DpOffset(0.dp, 14.dp),
                ),
            )
            .clip(CardShape)
            .background(colors.surfaceElevated)
            .border(0.5.dp, RealtimeFailureSecondaryColors.cardBorder(colors), CardShape)
            .padding(16.dp)
            .testTag("voice_realtime_failure_card"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(Brush.linearGradient(listOf(colors.warning, colors.warningText)), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.GraphicEq,
                    contentDescription = null,
                    tint = colors.onWarning,
                    modifier = Modifier.size(19.dp),
                )
            }
            Spacer(Modifier.width(12.dp))
            Text(
                text = stringResource(model.title, *model.titleArgs.toTypedArray()),
                style = OriveoTheme.typography.body.copy(
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                ),
                modifier = Modifier.weight(1f),
            )
        }
        if (model.buttons.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            // As iOS: the buttons share the row equally (one button spans it); the primary one sits at the end.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                model.buttons.drop(1).forEach { button ->
                    FailureButton(button, primary = false, enabled = enabled, onAction = onAction, modifier = Modifier.weight(1f))
                }
                FailureButton(
                    model.buttons.first(),
                    primary = true,
                    enabled = enabled,
                    onAction = onAction,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** Secondary button grey fill and text: same values as the secondary button in DictationPromptCard. */
internal object RealtimeFailureSecondaryColors {
    fun fill(isDark: Boolean): Color = if (isDark) Color.White.copy(alpha = 0.10f) else Color(0xFFF2F2F5)
    fun text(isDark: Boolean): Color = if (isDark) Color(0xFFEDEDEF) else Color(0xFF3F3F46)

    /** Card 0.5 hairline stroke uses border (light: black α0.08, dark: white α0.10); a light hairline is white α0.70, which is invisible on a white card. */
    fun cardBorder(colors: OriveoColors): Color = colors.border
}

@Composable
private fun FailureButton(
    button: RealtimeFailureButton,
    primary: Boolean,
    enabled: Boolean,
    onAction: (RealtimeFailureAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val fill = if (primary) {
        Modifier.background(OriveoGradients.primary, CircleShape)
    } else {
        Modifier.background(RealtimeFailureSecondaryColors.fill(OriveoTheme.isDark), CircleShape)
    }
    Box(
        modifier = modifier
            .heightIn(min = ButtonHeight)
            .testTag("voice_realtime_failure_action_${button.action.rawValue}")
            .clip(CircleShape)
            .then(fill)
            .clickable(enabled = enabled, role = Role.Button) { onAction(button.action) }
            .padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = stringResource(button.label),
            style = OriveoTheme.typography.body.copy(
                fontSize = 14.5.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (primary) OriveoGradients.onPrimary else RealtimeFailureSecondaryColors.text(OriveoTheme.isDark),
            ),
        )
    }
}
