package ai.oriveo.community.feature.chat.composer

import android.os.SystemClock
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.draw.innerShadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.SweepGradientShader
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.feature.chat.voice.VoiceGlyphs
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Dictation views for the composer input row (v3 visuals).
 * All stateless: the host maps controller state to these and wires the callbacks
 * (discard / finish(Insert) / finish(Send)). The timer ticks with delay(1000), the waveform redraws only
 * on new levels; the only infinite animation is the recording glow border (off under reduced motion).
 */

internal const val DICTATION_CAPSULE_TAG = "dictation_capsule"
/** The whole recording bar row (capsule + send), placed below the input frame. */
internal const val DICTATION_BAR_TAG = "dictation_bar"
internal const val DICTATION_GLOW_TAG = "dictation_glow_border"

/** Corner radius the glow border draws with, exposed for UI tests. */
internal val DictationGlowCornerRadiusKey = SemanticsPropertyKey<Dp>("DictationGlowCornerRadius")

// Busy row (unchanged v2 shell).
private val DictationShellShape = RoundedCornerShape(22.dp)
private val DictationShellBorder = 1.5.dp
private val DictationRowMinHeight = 44.dp
private val DictationMicButtonSize = 40.dp
private val DictationInnerButtonSize = 32.dp

// v3 recording capsule.
private val DictationCapsuleHeight = 56.dp
private val DictationCapsuleShape = RoundedCornerShape(28.dp)
private val DictationCloseSize = 44.dp
private val DictationTimerWidth = 34.dp
private val DictationDoneHeight = 40.dp
private val DictationDoneShape = RoundedCornerShape(20.dp)
private val DictationSendSize = 56.dp
private val DictationWaveHeight = 28.dp
private val DictationBarWidth = 3.dp
private val DictationBarCorner = 2.dp
private val DictationWavePadding = 4.dp
private val DictationGlowWidth = 2.dp

internal const val DICTATION_WAVE_BARS = 22

/** Timer and Done shrink to at most 0.75 of 15 sp (iOS minimumScaleFactor 0.75) instead of truncating. */
private val DictationBarTextAutoSize = TextAutoSize.StepBased(minFontSize = 11.25.sp, maxFontSize = 15.sp, stepSize = 0.25.sp)
private const val DICTATION_WAVE_MIN_DP = 4f
private const val DICTATION_WAVE_SPAN_DP = 22f

internal const val DICTATION_GLOW_PERIOD_MS = 6_000
internal const val DICTATION_GLOW_REST_DEGREES = 24f

/** Waveform palette ring; bar i is a vertical gradient from entry k to k + 1. */
internal val DICTATION_WAVE_COLORS = listOf(
    Color(0xFF6E8BFF),
    Color(0xFF9B6BFF),
    Color(0xFFE06BC4),
    Color(0xFFFFB36B),
    Color(0xFF66E0B8),
)

/**
 * Contract brand gradient for the send key and the card primary action (135°: top-left to bottom-right); fixed,
 * not following the palette (v3 voice contract).
 */
internal val DictationBrandGradient: Brush = Brush.linearGradient(
    listOf(Color(0xFF8347F5), Color(0xFF6B3BC7)), // dark-palette-guard: keep (c) v3 voice contract fixed purple
)

/**
 * Bar heights in dp, newest level on the right; missing levels count as silence.
 * height = 4 + round(22 × clamp(v × (0.8 + 0.2 sin(1.9 i)), 0, 1)).
 */
internal fun dictationWaveBarHeights(levels: List<Float>): List<Float> {
    val recent = levels.takeLast(DICTATION_WAVE_BARS)
    val padding = DICTATION_WAVE_BARS - recent.size
    return List(DICTATION_WAVE_BARS) { i ->
        val v = if (i < padding) 0f else recent[i - padding]
        val scaled = (v * (0.8f + 0.2f * sin(1.9f * i))).coerceIn(0f, 1f)
        DICTATION_WAVE_MIN_DP + (DICTATION_WAVE_SPAN_DP * scaled).roundToInt()
    }
}

/** Minimum gap between bars; when 22 bars do not fit the width, bars are dropped by this gap. */
private const val DICTATION_WAVE_MIN_GAP_DP = 1f

/** Bars that fit in a waveform [widthDp] wide (0..22), counting the 4 dp side padding (iOS visibleBarCount). */
internal fun dictationVisibleBarCount(widthDp: Float): Int {
    val usable = widthDp - 2 * DictationWavePadding.value + DICTATION_WAVE_MIN_GAP_DP
    if (usable <= 0f) return 0
    return minOf(DICTATION_WAVE_BARS, floor(usable / (DictationBarWidth.value + DICTATION_WAVE_MIN_GAP_DP)).toInt())
}

/** Top and bottom colors of bar [index]: palette entries k and k + 1, k = floor(i / 22 × 4). */
internal fun dictationWaveBarColors(index: Int): Pair<Color, Color> {
    val k = floor(index.toFloat() / DICTATION_WAVE_BARS * 4).toInt().coerceIn(0, DICTATION_WAVE_COLORS.size - 2)
    return DICTATION_WAVE_COLORS[k] to DICTATION_WAVE_COLORS[k + 1]
}

/** Glow border angle: one even turn per 6 s from the 24° rest angle; reduced motion stays at rest. */
internal fun dictationGlowDegrees(elapsedMillis: Long, reduceMotion: Boolean): Float {
    if (reduceMotion) return DICTATION_GLOW_REST_DEGREES
    val turn = elapsedMillis.mod(DICTATION_GLOW_PERIOD_MS.toLong()).toFloat() / DICTATION_GLOW_PERIOD_MS
    return (DICTATION_GLOW_REST_DEGREES + turn * 360f) % 360f
}

/**
 * Outer ring of the input frame: the slow glow border while [handle] records into this host slot,
 * [otherwise] in every other state (transcribing, cards and idle show no glow).
 */
@Composable
internal fun ComposerDictationGlowSlot(
    handle: DictationHostCoordinator?,
    cornerRadius: Dp,
    modifier: Modifier = Modifier,
    otherwise: @Composable () -> Unit,
) {
    if (handle == null) {
        otherwise()
        return
    }
    val state by handle.commands.state.collectAsStateWithLifecycle()
    val engineInfo by handle.commands.engineInfo.collectAsStateWithLifecycle()
    val row = dictationInputRow(state, handle.hostSlotKey, engineInfo ?: DictationEngineInfo.System)
    if (row is DictationInputRow.Recording) {
        DictationGlowBorder(cornerRadius = cornerRadius, modifier = modifier)
    } else {
        otherwise()
    }
}

/**
 * 2 dp sweep-gradient ring rotating once per 6 s. The shader is built once per size and only its local
 * matrix turns, read in the draw phase, so frames cost no recomposition or allocation.
 */
@Composable
internal fun DictationGlowBorder(
    cornerRadius: Dp,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    val elapsed: State<Float>? = if (reduceMotion) {
        null
    } else {
        rememberInfiniteTransition(label = "dictation-glow").animateFloat(
            initialValue = 0f,
            targetValue = DICTATION_GLOW_PERIOD_MS.toFloat(),
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = DICTATION_GLOW_PERIOD_MS, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = "dictation-glow-elapsed",
        )
    }
    Box(
        modifier = modifier
            .testTag(DICTATION_GLOW_TAG)
            .semantics { this[DictationGlowCornerRadiusKey] = cornerRadius }
            .drawWithCache {
            val center = Offset(size.width / 2f, size.height / 2f)
            val shader = SweepGradientShader(center = center, colors = AI_BORDER_COLORS)
            val brush = ShaderBrush(shader)
            val matrix = android.graphics.Matrix()
            val strokePx = DictationGlowWidth.toPx()
            val inset = strokePx / 2f
            val radiusPx = (cornerRadius.toPx() - inset).coerceAtLeast(0f)
            onDrawBehind {
                val degrees = dictationGlowDegrees(elapsed?.value?.toLong() ?: 0L, reduceMotion)
                matrix.setRotate(degrees, center.x, center.y)
                shader.setLocalMatrix(matrix)
                drawRoundRect(
                    brush = brush,
                    topLeft = Offset(inset, inset),
                    size = Size(size.width - strokePx, size.height - strokePx),
                    cornerRadius = CornerRadius(radiusPx),
                    style = Stroke(width = strokePx),
                )
            }
        },
    )
}

/**
 * Recording bar: [✕ timer waveform Done] in the v3 frosted capsule, plus the outer ↑ (transcribe and send).
 * [startedAt] is on the [now] clock (controller clock: elapsedRealtime). ↑ follows [canSend]
 * (same availability as the host send button).
 */
@Composable
internal fun ComposerDictationBar(
    startedAt: Long,
    levels: StateFlow<List<Float>>,
    canSend: Boolean,
    onDiscard: () -> Unit,
    onTranscribe: () -> Unit,
    onTranscribeAndSend: () -> Unit,
    modifier: Modifier = Modifier,
    now: () -> Long = SystemClock::elapsedRealtime,
) {
    val isDark = OriveoTheme.isDark

    Row(
        modifier = modifier.fillMaxWidth().testTag(DICTATION_BAR_TAG),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        DictationCapsule(modifier = Modifier.weight(1f)) {
            DictationIconButton(
                label = stringResource(R.string.voice_dictation_discard_recording),
                onClick = onDiscard,
                size = DictationCloseSize,
            ) {
                Icon(
                    painter = painterResource(VoiceGlyphs.closeDictation),
                    contentDescription = null,
                    modifier = Modifier.size(17.dp),
                    tint = if (isDark) Color(0xFFB3B3BA) else Color(0xFF52525B),
                )
            }
            // Timer and Done are measured first at full width (never truncated); the waveform takes the rest.
            DictationTimer(startedAt = startedAt, now = now)
            DictationWaveform(levels = levels, modifier = Modifier.weight(1f))
            DictationTranscribeButton(onClick = onTranscribe)
        }
        DictationSendButton(enabled = canSend, onClick = onTranscribeAndSend)
    }
}

/** Busy row while transcribing: label + indeterminate spinner; the only action is ✕ (cancel). */
@Composable
internal fun ComposerDictationBusyRow(
    label: DictationText,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val text = stringResource(label.res, *label.args.toTypedArray())
    DictationShell(modifier = modifier.fillMaxWidth()) {
        DictationIconButton(
            label = stringResource(R.string.voice_dictation_discard_recording),
            onClick = onCancel,
        ) {
            Icon(
                painter = painterResource(VoiceGlyphs.closeDictation),
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = colors.textSecondary,
            )
        }
        CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            color = colors.textSecondary,
            strokeWidth = 2.dp,
        )
        Text(
            text = text,
            modifier = Modifier.weight(1f),
            style = TextStyle(fontSize = 14.sp, color = colors.textSecondary),
            maxLines = 1,
        )
    }
}

/** Microphone key in the composer: starts dictation for the host slot. */
@Composable
internal fun DictationMicButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    // Light: brand ink @12% / dark: white @10%
    val flatFill = if (isDark) Color.White.copy(alpha = 0.10f) else colors.primary.copy(alpha = 0.12f)
    val label = stringResource(R.string.voice_dictate)
    Box(
        modifier = modifier
            .size(DictationMicButtonSize)
            .clip(CircleShape)
            .background(flatFill, CircleShape)
            .semantics { contentDescription = label }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Rounded.Mic,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = if (enabled) colors.textSecondary else colors.textTertiary,
        )
    }
}

/** v3 frosted capsule: 56 high, white α.86 with a violet hairline and soft violet shadow (dark: white α.08). */
@Composable
private fun DictationCapsule(
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    val isDark = OriveoTheme.isDark
    val shadow = if (isDark) {
        Modifier
    } else {
        Modifier.dropShadow(
            shape = DictationCapsuleShape,
            shadow = Shadow(radius = 26.dp, color = Color(0xFF5B21B6).copy(alpha = 0.12f), offset = DpOffset(0.dp, 10.dp)),
        )
    }
    val fill = if (isDark) Color.White.copy(alpha = 0.08f) else Color.White.copy(alpha = 0.86f)
    val hairline = if (isDark) Color.White.copy(alpha = 0.10f) else Color(0xFF7C3AED).copy(alpha = 0.16f) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
    Row(
        modifier = modifier
            .testTag(DICTATION_CAPSULE_TAG)
            // Minimum 56; grows with the Done key at large text so the row stays one line.
            .heightIn(min = DictationCapsuleHeight)
            .then(shadow)
            .clip(DictationCapsuleShape)
            .background(fill, DictationCapsuleShape)
            .border(0.5.dp, hairline, DictationCapsuleShape)
            .padding(start = 4.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        content = content,
    )
}

@Composable
private fun DictationShell(
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    val colors = OriveoTheme.colors
    // Static sweep gradient (no rotation) reusing the AI border palette.
    val borderBrush = remember { Brush.sweepGradient(AI_BORDER_COLORS) }
    Row(
        modifier = modifier
            .heightIn(min = DictationRowMinHeight)
            .clip(DictationShellShape)
            .background(colors.surfaceElevated.copy(alpha = 0.82f), DictationShellShape)
            .border(DictationShellBorder, borderBrush, DictationShellShape)
            .padding(horizontal = 6.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        content = content,
    )
}

@Composable
private fun DictationIconButton(
    label: String,
    onClick: () -> Unit,
    size: Dp = DictationInnerButtonSize,
    background: Brush = SolidColor(Color.Transparent),
    icon: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(background, CircleShape)
            .semantics { contentDescription = label }
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        icon()
    }
}

/** "Done" pill (iOS parity: a text key, not an icon); the text is the a11y label. */
@Composable
private fun DictationTranscribeButton(onClick: () -> Unit) {
    val isDark = OriveoTheme.isDark
    val textColor = if (isDark) Color(0xFFC4B5FD) else Color(0xFF6D28D9) // dark-palette-guard: keep (c) v3 voice contract fixed purple
    val fill = if (isDark) Color(0xFFA78BFA).copy(alpha = 0.18f) else Color(0xFF8C5FF8).copy(alpha = 0.10f) // dark-palette-guard: keep (c) v3 voice contract fixed purple; capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
    Box(
        modifier = Modifier
            .heightIn(min = DictationDoneHeight)
            .clip(DictationDoneShape)
            .background(fill, DictationDoneShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = stringResource(R.string.voice_dictation_transcribe),
            style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = textColor),
            maxLines = 1,
            softWrap = false,
            autoSize = DictationBarTextAutoSize,
        )
    }
}

/** 56 brand circle with a top inner highlight and violet shadow; flat and muted when disabled. */
/** Disabled ↑ fill (v3 voice contract): light = current palette brand ink @12%, dark = white @10%. */
@Composable
internal fun dictationSendDisabledFill(): Color =
    if (OriveoTheme.isDark) {
        Color.White.copy(alpha = 0.10f) // dark-palette-guard: keep (c) v3 voice contract
    } else {
        OriveoTheme.lightBrand.ink.copy(alpha = 0.12f)
    }

@Composable
private fun DictationSendButton(
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val label = stringResource(R.string.voice_dictation_transcribe_and_send)
    val decoration = if (enabled) {
        Modifier
            .dropShadow(
                shape = CircleShape,
                shadow = Shadow(radius = 22.dp, color = Color(0xFF7C3AED).copy(alpha = 0.32f), offset = DpOffset(0.dp, 10.dp)), // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
            )
            .background(DictationBrandGradient, CircleShape)
            .innerShadow(
                shape = CircleShape,
                shadow = Shadow(radius = 1.dp, color = Color.White.copy(alpha = 0.28f), offset = DpOffset(0.dp, 1.dp)),
            )
    } else {
        Modifier.background(dictationSendDisabledFill(), CircleShape)
    }
    Box(
        modifier = Modifier
            .size(DictationSendSize)
            .then(decoration)
            .clip(CircleShape)
            .semantics { contentDescription = label }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painter = painterResource(VoiceGlyphs.arrowUpward),
            contentDescription = null,
            modifier = Modifier.size(21.dp),
            tint = if (enabled) Color.White else colors.textTertiary,
        )
    }
}

/** Sample-sheet only: frozen recording-timer seconds. Takes effect only in DEBUG builds; the default null means the timer follows startedAt in real time. */
internal object DictationTimerShots {
    @Volatile
    var shotsFrozenSeconds: Int? = null

    /** The frozen seconds currently in effect; always null in release builds. */
    val effectiveFrozenSeconds: Int? get() = if (BuildConfig.DEBUG) shotsFrozenSeconds else null
}

/** Elapsed time m:ss from [startedAt], refreshed once per second. */
@Composable
private fun DictationTimer(
    startedAt: Long,
    now: () -> Long,
) {
    val isDark = OriveoTheme.isDark
    val frozenSeconds = DictationTimerShots.effectiveFrozenSeconds
    var elapsedMillis by remember(startedAt) { mutableLongStateOf((now() - startedAt).coerceAtLeast(0L)) }
    LaunchedEffect(startedAt, frozenSeconds) {
        // The timer does not advance while frozen; the sample always shows the checklist seconds.
        while (frozenSeconds == null) {
            elapsedMillis = (now() - startedAt).coerceAtLeast(0L)
            delay(1_000L)
        }
    }
    Text(
        text = formatDictationDuration(frozenSeconds?.toDouble() ?: (elapsedMillis / 1000.0)),
        modifier = Modifier.widthIn(min = DictationTimerWidth),
        // Tabular digits so the width does not jitter as seconds tick.
        style = TextStyle(
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (isDark) Color(0xFFD4D4D8) else Color(0xFF3F3F46),
            fontFeatureSettings = "tnum",
        ),
        maxLines = 1,
        softWrap = false,
        autoSize = DictationBarTextAutoSize,
    )
}

/**
 * Gradient bars from the level meter, justified edge to edge; newest on the right. When 22 bars do not fit
 * the width only the newest that fit are drawn (down to none); each keeps the color of its slot among the 22.
 */
@Composable
private fun DictationWaveform(
    levels: StateFlow<List<Float>>,
    modifier: Modifier = Modifier,
) {
    // Levels are read in the draw phase: a new level redraws the bars without recomposing.
    val values = levels.collectAsStateWithLifecycle()
    Canvas(modifier = modifier.height(DictationWaveHeight).padding(horizontal = DictationWavePadding)) {
        val heights = dictationWaveBarHeights(values.value)
        val barWidth = DictationBarWidth.toPx()
        val corner = DictationBarCorner.toPx()
        val count = dictationVisibleBarCount((size.width + 2 * DictationWavePadding.toPx()).toDp().value)
        val first = DICTATION_WAVE_BARS - count
        val step = if (count > 1) (size.width - barWidth) / (count - 1) else 0f
        for (i in first until DICTATION_WAVE_BARS) {
            val barHeight = heights[i].dp.toPx()
            val top = (size.height - barHeight) / 2
            val (topColor, bottomColor) = dictationWaveBarColors(i)
            // A single bar sits at the trailing (newest) end.
            val left = if (count > 1) step * (i - first) else size.width - barWidth
            drawRoundRect(
                brush = Brush.verticalGradient(listOf(topColor, bottomColor), startY = top, endY = top + barHeight),
                topLeft = Offset(left, top),
                size = Size(barWidth, barHeight),
                cornerRadius = CornerRadius(corner, corner),
            )
        }
    }
}
