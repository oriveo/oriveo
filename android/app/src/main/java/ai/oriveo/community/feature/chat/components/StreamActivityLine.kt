package ai.oriveo.community.feature.chat.components

import androidx.annotation.StringRes
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import ai.oriveo.community.R
import ai.oriveo.community.core.model.StreamActivity
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.receiveAsFlow

/** The visible content has to stay unchanged for this long before it counts as a pause. */
internal const val STREAM_QUIET_THRESHOLD_MS = 1500L

private const val SHIMMER_PERIOD_MS = 1800
private const val SHIMMER_BAND_FRACTION = 0.3f
private const val APPEAR_FADE_MS = 200

/** The kinds of waiting label. The neutral one reuses the existing `generating` string. */
internal enum class StreamActivityLabel(@param:StringRes val stringRes: Int) {
    Generating(R.string.generating),
    WebSearch(R.string.stream_activity_web_search),

    /**
     * Fallback when there is no display context ("Using a tool"). When the message has a running
     * step, the caller replaces it with "Using <server name> - <tool title>"
     * ([streamActivityLabelText]).
     */
    McpTool(R.string.mcp_steps_running),
}

internal fun StreamActivity.label(): StreamActivityLabel = when (this) {
    StreamActivity.WebSearch -> StreamActivityLabel.WebSearch
    StreamActivity.McpTool -> StreamActivityLabel.McpTool
}

/**
 * The final text of the waiting label. An MCP tool's display context (server name and tool title,
 * third-party text shown untranslated) does not travel with the activity event; it is read from
 * the step currently running in the message's `toolSteps`.
 */
@Composable
internal fun streamActivityLabelText(
    label: StreamActivityLabel,
    toolSteps: List<ai.oriveo.community.core.mcp.McpToolStep>?,
): String {
    if (label == StreamActivityLabel.McpTool) {
        val running = toolSteps?.lastOrNull {
            it.status == ai.oriveo.community.core.mcp.McpToolStepUpdate.Status.Running.wireValue
        }
        if (running != null) {
            return androidx.compose.ui.res.stringResource(
                R.string.stream_activity_mcp_tool,
                running.serverName,
                running.displayTitle,
            )
        }
    }
    return androidx.compose.ui.res.stringResource(label.stringRes)
}

/** What to show while waiting. At most one waiting label is on screen at a time. */
internal sealed interface StreamActivityPresentation {
    data object Hidden : StreamActivityPresentation

    /** The typing indicator is on screen: it carries the label and no line is stacked on top. */
    data class IndicatorLabel(val label: StreamActivityLabel) : StreamActivityPresentation

    /** The typing indicator is gone (body text exists, or the reasoning block replaced it): the line under the body carries the label. */
    data class StatusLine(val label: StreamActivityLabel) : StreamActivityPresentation
}

/** Decides the waiting feedback for a generating message. A pure function, one branch per rule. */
internal fun resolveStreamActivityPresentation(
    isGenerating: Boolean,
    hasBodyText: Boolean,
    typingIndicatorVisible: Boolean,
    activity: StreamActivity?,
    quiet: Boolean,
): StreamActivityPresentation = when {
    !isGenerating -> StreamActivityPresentation.Hidden
    activity != null && typingIndicatorVisible -> StreamActivityPresentation.IndicatorLabel(activity.label())
    activity != null -> StreamActivityPresentation.StatusLine(activity.label())
    quiet && hasBodyText -> StreamActivityPresentation.StatusLine(StreamActivityLabel.Generating)
    else -> StreamActivityPresentation.Hidden
}

/**
 * Pause timer: [quiet] turns true once [STREAM_QUIET_THRESHOLD_MS] has passed since the last
 * [noteVisibleChange] with no new visible change, and turns back to false on the next change.
 *
 * Changes travel through a conflated channel rather than snapshot state. The body commits in
 * chunks at about 8 Hz, and writing a state that AssistantMessage reads on each of them would
 * recompose the whole streaming cell once more every time. Here only a flip of [quiet] recomposes.
 */
@Stable
internal class StreamQuietState {
    var quiet by mutableStateOf(false)
        private set

    private val changes = Channel<Unit>(Channel.CONFLATED)

    fun noteVisibleChange() {
        changes.trySend(Unit)
    }

    /** Runs in a LaunchedEffect of the streaming message; cancelling it (stream ended, cell left the screen) resets the state. */
    suspend fun run(thresholdMs: Long = STREAM_QUIET_THRESHOLD_MS) {
        try {
            // Send one on entry: the clock starts when observation starts, rather than assuming
            // the content has already been still for the whole threshold.
            changes.trySend(Unit)
            changes.receiveAsFlow().collectLatest {
                quiet = false
                delay(thresholdMs)
                quiet = true
            }
        } finally {
            quiet = false
        }
    }
}

/**
 * A single line of waiting text with a one-colour shimmer. No icon, no dots, no ellipsis.
 *
 * The shimmer reads the animation value in the draw phase, so it does not recompose. The
 * highlight is drawn over the finished text with SrcAtop rather than through
 * `SpanStyle(brush = ShaderBrush)`, which fails with
 * `A derived state calculation cannot read itself`.
 */
@Composable
internal fun StreamActivityLine(
    text: String,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    val isRtl = LocalLayoutDirection.current == LayoutDirection.Rtl

    // Fades in on appearing. To disappear the caller simply drops it from the composition: it
    // must not keep its space while the body goes on printing.
    val appear = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        appear.animateTo(1f, tween(durationMillis = APPEAR_FADE_MS, easing = LinearEasing))
    }

    val sweep = if (reduceMotion) {
        null
    } else {
        rememberInfiniteTransition(label = "stream_activity_shimmer").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = SHIMMER_PERIOD_MS, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = "stream_activity_shimmer_progress",
        )
    }
    val highlight = colors.textPrimary

    Text(
        text = text,
        style = OriveoTheme.typography.footnote,
        color = if (reduceMotion) colors.textSecondary else colors.textTertiary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .semantics { liveRegion = LiveRegionMode.Polite }
            .graphicsLayer {
                alpha = appear.value
                // SrcAtop can only blend onto this layer's own pixels, so it has to composite offscreen.
                compositingStrategy = CompositingStrategy.Offscreen
            }
            .then(
                if (sweep == null) {
                    Modifier
                } else {
                    Modifier.drawWithContent {
                        drawContent()
                        val band = size.width * SHIMMER_BAND_FRACTION
                        // The band sweeps from just outside the start edge of the text to just outside the
                        // end edge, mirrored in RTL.
                        val travelled = (size.width + band) * sweep.value
                        val left = if (isRtl) size.width - travelled else travelled - band
                        drawRect(
                            brush = Brush.horizontalGradient(
                                0f to highlight.copy(alpha = 0f),
                                0.5f to highlight,
                                1f to highlight.copy(alpha = 0f),
                                startX = left,
                                endX = left + band,
                            ),
                            topLeft = Offset(left, 0f),
                            size = Size(band, size.height),
                            blendMode = BlendMode.SrcAtop,
                        )
                    }
                },
            ),
    )
}
