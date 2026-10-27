package ai.oriveo.community.feature.chat.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.KeepScreenOnHolds
import ai.oriveo.community.core.voice.ReadAloudController
import ai.oriveo.community.core.voice.ReadAloudEndReason
import ai.oriveo.community.core.voice.ReadAloudState
import ai.oriveo.community.core.voice.speakableSegments
import ai.oriveo.community.feature.chat.AssistantMessageFooterMetrics
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.compose.koinInject

private val ReadAloudRingSize = 26.dp
private val ReadAloudRingStroke = 2.dp
private val ReadAloudStopSize = 8.dp

/**
 * Read-aloud button in the assistant message footer: a speaker when idle; while reading it becomes a 26dp progress ring
 * with a stop square, keeping the same size. Failed looks the same as idle. Hidden when eligible is false or there is nothing to read.
 */
@Composable
fun ReadAloudButton(
    messageId: String,
    messageText: String,
    eligible: Boolean,
    modifier: Modifier = Modifier,
) {
    val hasSegments = remember(messageText) { speakableSegments(messageText, final = true).isNotEmpty() }
    if (!eligible || !hasSegments) return

    val controller = koinInject<ReadAloudController>()
    val voiceConversation = remember {
        org.koin.mp.KoinPlatform.getKoinOrNull()
            ?.getOrNull<ai.oriveo.community.core.voice.conversation.VoiceConversationController>()
    }
    val realtimeSessions = remember {
        org.koin.mp.KoinPlatform.getKoinOrNull()
            ?.getOrNull<ai.oriveo.community.feature.chat.voice.RealtimeVoiceSessionBuilder>()
    }
    val state by controller.state.collectAsStateWithLifecycle()
    val speaking = (state as? ReadAloudState.Speaking)?.takeIf { it.messageId == messageId }
    val colors = OriveoTheme.colors

    // Hold keep-screen-on while reading (shares the per-View hold count with dictation recording); released on leaving or finishing
    val view = LocalView.current
    val isSpeaking = speaking != null
    val keepAwakeHolder = remember { Any() }
    DisposableEffect(view, isSpeaking) {
        if (!isSpeaking) return@DisposableEffect onDispose {}
        KeepScreenOnHolds.views.acquire(view, keepAwakeHolder)
        onDispose { KeepScreenOnHolds.views.release(view, keepAwakeHolder) }
    }

    val label = stringResource(if (isSpeaking) R.string.voice_stop_reading else R.string.voice_read_aloud)
    val progressLabel = speaking?.let {
        stringResource(R.string.voice_read_aloud_progress, it.index + 1, it.total)
    }
    val progress by animateFloatAsState(
        // Draw (index+1)/total so a single sentence never shows an empty ring (same as iOS)
        targetValue = speaking?.let { if (it.total > 0) (it.index + 1).toFloat() / it.total else 0f } ?: 0f,
        label = "readAloudProgress",
    )

    Box(
        modifier = modifier
            .size(AssistantMessageFooterMetrics.IconTouchSize)
            .clip(RoundedCornerShape(AssistantMessageFooterMetrics.CornerRadius))
            .semantics {
                contentDescription = label
                if (progressLabel != null) stateDescription = progressLabel
            }
            .clickable(
                role = Role.Button,
                // During a voice conversation the message plays in the conversation's own audio pipeline.
                onClick = {
                    val conversation = voiceConversation
                    if (realtimeSessions?.realtimeActive == true) {
                        // No read aloud while a realtime session runs.
                    } else if (conversation?.active?.value == true) {
                        conversation.playMessage(messageId, messageText)
                    } else {
                        controller.toggle(messageId, messageText)
                    }
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (speaking == null) {
            Icon(
                imageVector = Icons.AutoMirrored.Rounded.VolumeUp,
                contentDescription = null,
                modifier = Modifier.size(AssistantMessageFooterMetrics.IconSize),
                tint = colors.textTertiary,
            )
        } else {
            val trackColor = colors.border
            // CompositionLocals cannot be read inside a DrawScope, so the palette-following gradient is read during composition
            val brandBrush = OriveoGradients.primary
            Canvas(modifier = Modifier.size(ReadAloudRingSize)) {
                val strokePx = ReadAloudRingStroke.toPx()
                val inset = strokePx / 2
                val arcSize = Size(size.width - strokePx, size.height - strokePx)
                val topLeft = Offset(inset, inset)
                drawArc(
                    color = trackColor,
                    startAngle = 0f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = strokePx),
                )
                drawArc(
                    brush = brandBrush,
                    startAngle = -90f,
                    sweepAngle = 360f * progress,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = strokePx, cap = StrokeCap.Round),
                )
            }
            Box(
                modifier = Modifier
                    .size(ReadAloudStopSize)
                    .clip(RoundedCornerShape(2.dp))
                    .background(brandBrush),
            )
        }
    }
}

/**
 * Attach once per chat screen: stops on conversation change (navigated), when a new reply starts streaming (new_generation)
 * and when leaving the chat screen (navigated). Message ids are not passed: the list is a paged window, so stopping on
 * "not in the list" would stop messages that still exist, and idle recompositions avoid mapping the whole list.
 */
@Composable
fun ReadAloudChatEffect(
    conversationId: String?,
    streamingMessageId: String?,
) {
    val controller = koinInject<ReadAloudController>()
    LaunchedEffect(controller, conversationId, streamingMessageId) {
        controller.observeChat(conversationId, streamingMessageId)
    }
    DisposableEffect(controller) {
        onDispose { controller.stop(ReadAloudEndReason.NAVIGATED) }
    }
}
