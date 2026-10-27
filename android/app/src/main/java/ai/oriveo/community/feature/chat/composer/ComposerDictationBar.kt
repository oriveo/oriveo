package ai.oriveo.community.feature.chat.composer

import android.os.SystemClock
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.DictationLevelMeter
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow

/**
 * Dictation views for the composer input row. All stateless: the host
 * maps controller state to these and wires the callbacks (discard / finish(Insert) / finish(Send)).
 * No infinite animation: the timer ticks with delay(1000), the waveform redraws only on new levels.
 */

private val DictationShellShape = RoundedCornerShape(22.dp)
private val DictationShellBorder = 1.5.dp
private val DictationRowMinHeight = 44.dp
private val DictationButtonSize = 40.dp
private val DictationInnerButtonSize = 32.dp
private val DictationWaveHeight = 22.dp
private val DictationBarWidth = 2.5.dp
private const val DICTATION_WAVE_BARS = DictationLevelMeter.CAPACITY
private const val DICTATION_WAVE_MIN_FRACTION = 0.12f

/**
 * Recording bar: [✕ timer waveform ✓] in a translucent shell, plus the outer up arrow (transcribe and send).
 * [startedAt] is on the [now] clock (controller clock: elapsedRealtime). The up arrow follows [canSend]
 * (same availability as the host send button). Keeps the screen on while in composition.
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
    val colors = OriveoTheme.colors

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        DictationShell(modifier = Modifier.weight(1f)) {
            DictationIconButton(
                label = stringResource(R.string.voice_dictation_discard_recording),
                onClick = onDiscard,
            ) {
                Icon(
                    imageVector = Icons.Rounded.Close,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = colors.textSecondary,
                )
            }
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
                imageVector = Icons.Rounded.Close,
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
    // dark-palette-guard: keep (d) light branch
    val flatFill = if (isDark) Color.White.copy(alpha = 0.10f) else Color(0xFF8C5FF8).copy(alpha = 0.12f)
    val label = stringResource(R.string.voice_dictate)
    Box(
        modifier = modifier
            .size(DictationButtonSize)
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
    background: Brush = SolidColor(Color.Transparent),
    icon: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(DictationInnerButtonSize)
            .clip(CircleShape)
            .background(background, CircleShape)
            .semantics { contentDescription = label }
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        icon()
    }
}

/** Compact text pill "Transcribe" (iOS parity: a text key, not an icon); the text is the a11y label. */
@Composable
private fun DictationTranscribeButton(onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .height(DictationInnerButtonSize)
            .clip(CircleShape)
            .background(colors.primary.copy(alpha = 0.12f), CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = stringResource(R.string.voice_dictation_transcribe),
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = colors.primary),
            maxLines = 1,
        )
    }
}

@Composable
private fun DictationSendButton(
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val label = stringResource(R.string.voice_dictation_transcribe_and_send)
    val background: Brush = if (enabled) OriveoGradients.primary else SolidColor(colors.textPrimary.copy(alpha = 0.08f))
    Box(
        modifier = Modifier
            .size(DictationButtonSize)
            .clip(CircleShape)
            .background(background, CircleShape)
            .semantics { contentDescription = label }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.ArrowUpward,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = if (enabled) OriveoGradients.onPrimary else colors.textTertiary,
        )
    }
}

/** Sample-only: frozen recording seconds. Only effective in DEBUG builds; default null = tick live from startedAt. */
internal object DictationTimerShots {
    @Volatile
    var shotsFrozenSeconds: Int? = null

    /** Currently effective frozen seconds; always null in release. */
    val effectiveFrozenSeconds: Int? get() = if (BuildConfig.DEBUG) shotsFrozenSeconds else null
}

/** Elapsed time m:ss from [startedAt], refreshed once per second. */
@Composable
private fun DictationTimer(
    startedAt: Long,
    now: () -> Long,
) {
    val colors = OriveoTheme.colors
    val frozenSeconds = DictationTimerShots.effectiveFrozenSeconds
    var elapsedMillis by remember(startedAt) { mutableLongStateOf((now() - startedAt).coerceAtLeast(0L)) }
    LaunchedEffect(startedAt, frozenSeconds) {
        // When frozen, don't tick; the sample always shows the manifest seconds.
        while (frozenSeconds == null) {
            elapsedMillis = (now() - startedAt).coerceAtLeast(0L)
            delay(1_000L)
        }
    }
    Text(
        text = formatDictationDuration(frozenSeconds?.toDouble() ?: (elapsedMillis / 1000.0)),
        // Tabular digits so the width does not jitter as seconds tick.
        style = TextStyle(
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = colors.textPrimary,
            fontFeatureSettings = "tnum",
        ),
        maxLines = 1,
    )
}

/** 24 vertical bars from the level meter; newest on the right, missing levels drawn at the floor. */
@Composable
private fun DictationWaveform(
    levels: StateFlow<List<Float>>,
    modifier: Modifier = Modifier,
) {
    val values by levels.collectAsStateWithLifecycle()
    val barColor = OriveoTheme.colors.textSecondary
    Canvas(modifier = modifier.height(DictationWaveHeight)) {
        val barWidth = DictationBarWidth.toPx()
        val step = size.width / DICTATION_WAVE_BARS
        val padding = DICTATION_WAVE_BARS - values.size.coerceAtMost(DICTATION_WAVE_BARS)
        val recent = values.takeLast(DICTATION_WAVE_BARS)
        for (i in 0 until DICTATION_WAVE_BARS) {
            val level = if (i < padding) 0f else recent[i - padding]
            val fraction = level.coerceIn(0f, 1f).coerceAtLeast(DICTATION_WAVE_MIN_FRACTION)
            val barHeight = size.height * fraction
            val x = step * i + (step - barWidth) / 2
            drawRoundRect(
                color = barColor,
                topLeft = Offset(x, (size.height - barHeight) / 2),
                size = Size(barWidth, barHeight),
                cornerRadius = CornerRadius(barWidth / 2, barWidth / 2),
            )
        }
    }
}
