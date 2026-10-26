package ai.oriveo.community.feature.chat.voice

import android.content.Intent
import android.util.Log
import androidx.annotation.StringRes
import androidx.annotation.VisibleForTesting
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.MicOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.feature.chat.composer.AI_BORDER_COLORS
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.StateFlow

/** Which page hosts the bar; it decides the statuses the bar can legitimately show. */
enum class VoiceConversationPage { Home, Chat }

/** Status words of the bar and the statuses each page can reach. */
object VoiceConversationBarStatus {
    /** Debug builds only: how many times the bar rendered a status [reachable] rules out; smoke cases assert 0. */
    @VisibleForTesting
    val unreachableHits = AtomicInteger(0)

    /**
     * Home only ever listens, thinks, is muted or fails: the first transcript hands over to the chat page before any
     * reply. Anything else on home is a bug. The chat page reaches all seven.
     */
    fun reachable(page: VoiceConversationPage): Set<ConversationStatusKey> = when (page) {
        VoiceConversationPage.Home -> setOf(
            ConversationStatusKey.LISTENING,
            ConversationStatusKey.THINKING,
            ConversationStatusKey.MUTED,
            ConversationStatusKey.ERROR,
        )
        VoiceConversationPage.Chat -> ConversationStatusKey.entries.toSet()
    }

    @StringRes
    fun label(key: ConversationStatusKey): Int = when (key) {
        ConversationStatusKey.LISTENING -> R.string.voice_conversation_status_listening
        ConversationStatusKey.THINKING -> R.string.voice_conversation_status_thinking
        ConversationStatusKey.SPEAKING -> R.string.voice_conversation_status_speaking
        ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT -> R.string.voice_conversation_status_speaking_tap_to_interrupt
        ConversationStatusKey.MUTED -> R.string.voice_conversation_status_muted
        ConversationStatusKey.AWAITING_APPROVAL -> R.string.voice_conversation_status_awaiting_approval
        ConversationStatusKey.ERROR -> R.string.voice_conversation_status_error
    }

    /** Accessibility action label of the orb (what a tap does); null = the tap does nothing in this status. */
    @StringRes
    fun tapHint(key: ConversationStatusKey): Int? = when (key) {
        ConversationStatusKey.LISTENING -> R.string.voice_conversation_orb_hint_listening
        ConversationStatusKey.THINKING -> R.string.voice_conversation_orb_hint_thinking
        ConversationStatusKey.SPEAKING, ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT ->
            R.string.voice_conversation_orb_hint_speaking
        ConversationStatusKey.MUTED -> R.string.voice_conversation_unmute_a11y
        ConversationStatusKey.AWAITING_APPROVAL, ConversationStatusKey.ERROR -> null
    }
}

/**
 * DEBUG-only screenshot hook: launching with the intent extra
 * `VOICE_CONVERSATION_DEMO=<status raw value>` (listening, thinking, speaking, speakingTapToInterrupt, muted,
 * awaitingApproval, error) shows the voice bar frozen in that status on home and chat. No microphone, no sound,
 * no controller.
 */
object VoiceConversationDemo {
    const val EXTRA = "VOICE_CONVERSATION_DEMO"

    var status: ConversationStatusKey? = null
        private set

    fun capture(intent: Intent?) {
        if (!BuildConfig.DEBUG) return
        val raw = intent?.getStringExtra(EXTRA) ?: return
        status = parse(raw)
    }

    /** DEBUG-only shot entry: freezes the bar in [status] (null = no demo, the real host runs). No-op in release. */
    fun show(status: ConversationStatusKey?) {
        if (!BuildConfig.DEBUG) return
        this.status = status
    }

    /** Status raw value (listening, thinking, …) → key; unknown → null. */
    fun parse(raw: String?): ConversationStatusKey? = ConversationStatusKey.entries.firstOrNull { it.rawValue == raw }
}

private val BarShape = RoundedCornerShape(22.dp)
private val BarBorderWidth = 1.5.dp
private val BarMinHeight = 56.dp
private val SideTouchSize = 48.dp
private val SideCircleSize = 40.dp
private val OrbSize = 32.dp
private val StatusFontSizes = listOf(16.sp, 15.sp, 14.sp, 13.sp)

/**
 * Voice conversation bar: ✕ on the left, the orb + one status word in the middle (one ≥ 48 dp
 * button → [onTapOrb]), mute on the right (slashed mic, inverted while muted). Translucent shell with a static
 * 1.5 dp sweep border in the AI palette, 22 dp corners. The only infinite animation is the orb's flow while
 * thinking, and it is skipped when system animations are off.
 *
 * The status word is not a live region: the host announces it once per change.
 */
@Composable
fun VoiceConversationBar(
    status: ConversationStatusKey,
    level: StateFlow<Float>?,
    page: VoiceConversationPage,
    onEnd: () -> Unit,
    onTapOrb: () -> Unit,
    onToggleMute: () -> Unit,
    modifier: Modifier = Modifier,
    /** Test hook: layout of the status word (truncation checks). */
    onStatusLayout: ((TextLayoutResult) -> Unit)? = null,
    /** entrance / exit driven by [VoiceConversationSwitcher]; null = shown as is. */
    motion: VoiceBarMotion? = null,
) {
    if (status !in VoiceConversationBarStatus.reachable(page)) {
        // Unreachable by design (see VoiceConversationBarStatus.reachable); rendered anyway, reported in debug.
        if (BuildConfig.DEBUG) {
            Log.w("VoiceConversationBar", "status ${status.rawValue} is unreachable on $page")
            VoiceConversationBarStatus.unreachableHits.incrementAndGet()
        }
    }
    val colors = OriveoTheme.colors
    val borderBrush = remember { Brush.sweepGradient(AI_BORDER_COLORS) }
    val muted = status == ConversationStatusKey.MUTED
    Row(
        modifier = modifier
            .fillMaxWidth()
            .graphicsLayer { motion?.let { alpha = it.frame().barAlpha } }
            .heightIn(min = BarMinHeight)
            .clip(BarShape)
            .background(colors.surfaceElevated.copy(alpha = 0.82f), BarShape)
            .border(BarBorderWidth, borderBrush, BarShape)
            .padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BarCircleButton(
            label = stringResource(R.string.voice_conversation_end_a11y),
            tag = "voice_conversation_end_button",
            inverted = false,
            motion = motion,
            onClick = onEnd,
        ) { tint ->
            Icon(Icons.Rounded.Close, contentDescription = null, modifier = Modifier.size(20.dp), tint = tint)
        }
        OrbButton(
            status = status,
            level = level,
            onTap = onTapOrb,
            onStatusLayout = onStatusLayout,
            motion = motion,
            modifier = Modifier.weight(1f),
        )
        BarCircleButton(
            label = stringResource(if (muted) R.string.voice_conversation_unmute_a11y else R.string.voice_conversation_mute_a11y),
            tag = "voice_conversation_mute_button",
            inverted = muted,
            motion = motion,
            onClick = onToggleMute,
        ) { tint ->
            Icon(Icons.Rounded.MicOff, contentDescription = null, modifier = Modifier.size(20.dp), tint = tint)
        }
    }
}

@Composable
private fun BarCircleButton(
    label: String,
    tag: String,
    inverted: Boolean,
    motion: VoiceBarMotion?,
    onClick: () -> Unit,
    icon: @Composable (Color) -> Unit,
) {
    val colors = OriveoTheme.colors
    val fill = if (inverted) colors.textPrimary else colors.textPrimary.copy(alpha = 0.06f)
    val tint = if (inverted) colors.background else colors.textSecondary
    Box(
        modifier = Modifier
            .graphicsLayer {
                motion?.let {
                    val scale = it.frame().sideScale
                    scaleX = scale
                    scaleY = scale
                }
            }
            .size(SideTouchSize)
            .clip(CircleShape)
            .semantics { contentDescription = label }
            .testTag(tag)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier.size(SideCircleSize).background(fill, CircleShape),
            contentAlignment = Alignment.Center,
        ) { icon(tint) }
    }
}

@Composable
private fun OrbButton(
    status: ConversationStatusKey,
    level: StateFlow<Float>?,
    onTap: () -> Unit,
    onStatusLayout: ((TextLayoutResult) -> Unit)?,
    motion: VoiceBarMotion?,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val label = stringResource(VoiceConversationBarStatus.label(status))
    val hint = VoiceConversationBarStatus.tapHint(status)?.let { stringResource(it) }
    Row(
        modifier = modifier
            .heightIn(min = SideTouchSize)
            .widthIn(min = SideTouchSize)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onTap)
            .clearAndSetSemantics {
                contentDescription = label
                testTag = "voice_conversation_orb_button"
                role = Role.Button
                onClick(label = hint) {
                    onTap()
                    true
                }
            }
            .testTag("voice_conversation_orb_button")
            .padding(horizontal = 4.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        VoiceOrb(status = status, level = level, motion = motion)
        // Long words (e.g. "speaking · tap to interrupt" in some locales) step down in size before they would be
        // cut off; two lines at most.
        var fontSize by remember(label) { mutableStateOf(StatusFontSizes.first()) }
        Text(
            text = label,
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold, fontSize = fontSize),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { result ->
                val cut = result.lineCount > 0 && result.isLineEllipsized(result.lineCount - 1)
                val smaller = StatusFontSizes.firstOrNull { it < fontSize }
                if (cut && smaller != null) fontSize = smaller else onStatusLayout?.invoke(result)
            },
            modifier = Modifier.weight(1f, fill = false),
        )
    }
}

/**
 * The orb: layered radial gradients clipped to one circle (no seams). Listening / speaking scale with
 * the level; thinking lets two inner color pools drift back and forth (no rotation); muted dims; approval / error
 * stay still. With system animations off the level only changes opacity and nothing drifts.
 */
@Composable
internal fun VoiceOrb(
    status: ConversationStatusKey,
    level: StateFlow<Float>?,
    motion: VoiceBarMotion?,
    @VisibleForTesting onComposed: (() -> Unit)? = null,
) {
    if (onComposed != null) SideEffect(onComposed)
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    val follows = status == ConversationStatusKey.LISTENING ||
        status == ConversationStatusKey.SPEAKING ||
        status == ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT
    val thinking = status == ConversationStatusKey.THINKING
    val collected = level?.collectAsStateWithLifecycle()?.value ?: 0f
    val rawLevel = if (follows) collected else 0f
    val smoothed by animateFloatAsState(
        targetValue = rawLevel.coerceIn(0f, 1f),
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "voice-orb-level",
    )
    // Kept as State and read only inside the draw lambda: each animation frame redraws, it never recomposes.
    var driftA: State<Float>? = null
    var driftB: State<Float>? = null
    if (thinking && !reduceMotion) {
        val flow = rememberInfiniteTransition(label = "voice-orb-flow")
        driftA = flow.animateFloat(
            initialValue = -1f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(2600, easing = LinearEasing), RepeatMode.Reverse),
            label = "voice-orb-flow-a",
        )
        driftB = flow.animateFloat(
            initialValue = 1f,
            targetValue = -1f,
            animationSpec = infiniteRepeatable(tween(3700, easing = LinearEasing), RepeatMode.Reverse),
            label = "voice-orb-flow-b",
        )
    }
    val dimmed = status == ConversationStatusKey.MUTED
    Canvas(
        modifier = Modifier
            .then(
                if (motion == null) {
                    Modifier
                } else {
                    // Reported outside the travel layer, so the start point doesn't move with the orb.
                    Modifier
                        .onGloballyPositioned { motion.orbCenter = it.boundsInWindow().center }
                        .graphicsLayer {
                            val offset = motion.frame().orbOffset
                            translationX = offset.x
                            translationY = offset.y
                        }
                },
            )
            .size(OrbSize)
            .graphicsLayer {
                if (reduceMotion) {
                    alpha = if (dimmed) 0.45f else 0.7f + 0.3f * smoothed
                } else {
                    val scale = 1f + 0.22f * smoothed
                    scaleX = scale
                    scaleY = scale
                    alpha = if (dimmed) 0.45f else 1f
                }
            },
    ) {
        val r = size.minDimension / 2f
        val c = center
        val shiftA = driftA?.value ?: 0f
        val shiftB = driftB?.value ?: 0f
        drawCircle(
            brush = Brush.radialGradient(
                listOf(Color(0xFF9B6BFF), Color(0xFF6E8BFF)),
                center = c + Offset(-0.2f * r, -0.25f * r),
                radius = r * 1.3f,
            ),
            radius = r,
            center = c,
        )
        drawCircle(
            brush = Brush.radialGradient(
                listOf(Color(0xD9E06BC4), Color.Transparent),
                center = c + Offset(0.35f * r + 0.3f * r * shiftA, 0.3f * r),
                radius = r * 0.95f,
            ),
            radius = r,
            center = c,
        )
        drawCircle(
            brush = Brush.radialGradient(
                listOf(Color(0x9966E0B8), Color.Transparent),
                center = c + Offset(-0.3f * r, 0.4f * r + 0.3f * r * shiftB),
                radius = r * 0.75f,
            ),
            radius = r,
            center = c,
        )
        drawCircle(
            brush = Brush.radialGradient(
                listOf(Color.White.copy(alpha = 0.75f), Color.Transparent),
                center = c + Offset(-0.32f * r, -0.4f * r),
                radius = r * 0.55f,
            ),
            radius = r,
            center = c,
        )
    }
}

/** Status word announcement hook for the bar's host; see [StatusAnnouncer]. */
@Composable
fun AnnounceVoiceStatus(status: ConversationStatusKey?, announcer: StatusAnnouncer) {
    val text = status?.let { stringResource(VoiceConversationBarStatus.label(it)) }
    LaunchedEffect(text) { if (text != null) announcer.announce(text) }
}
