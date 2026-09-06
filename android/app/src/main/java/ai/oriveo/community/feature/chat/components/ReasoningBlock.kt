package ai.oriveo.community.feature.chat.components

import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.ripple
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.markdown.LocalMarkdownTextScale
import ai.oriveo.community.ui.component.markdown.MarkdownMessageView
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlin.math.max

/**
 * Collapsible reasoning block, similar in spirit to the "Thinking… / Thought for Ns"
 * collapse UI seen in other chat products.
 *
 * Three states:
 *  - **Streaming**: pulsing dot + "Thinking…"; expanded by default before any body
 *    text arrives, then automatically collapses once the first body chunk lands.
 *  - **Finished**: chevron + "Thought for {duration}", tap to expand/collapse.
 *  - **History fallback**: duration == null -> "Show thinking" / "Hide thinking".
 *
 * State machine: `userExpanded ?: autoExpanded`. Tapping the header flips and pins
 * [userExpanded]; switching messages (the [messageId] key changes) resets
 * [userExpanded] back to null so it follows automatic behavior again.
 *
 * Performance: whether [reasoningText] is backed by an [androidx.compose.runtime.State]
 * or a plain String is up to the caller. The internal markdown rendering shares the
 * same cached [MarkdownMessageView] path used for regular message bodies.
 *
 * Accessibility: the header row is a Button whose [stateDescription] reports
 * "expanded"/"collapsed"; the chevron uses
 * `Icons.AutoMirrored.Outlined.KeyboardArrowRight`, which auto-mirrors under RTL.
 */
@Composable
fun ReasoningBlock(
    reasoningText: String,
    isStreaming: Boolean,
    durationMs: Long?,
    messageId: String,
    modifier: Modifier = Modifier,
    /**
     * Whether the reasoning phase itself has actually finished (body text has started
     * streaming out, or the duration has been finalized). [isStreaming] is a
     * **message-level** signal: it can stay true for tens of seconds after reasoning has
     * already ended while the body is still generating -- if the expanded view kept
     * withholding content behind a safe-prefix filter during that window, a reasoning
     * tail ending in a table or an unclosed `$$` would never show up. Once reasoning has
     * actually ended, its content is final, so it switches straight to the finished-state
     * full render (the same path used when the whole message completes, so there's no new visual jump).
     */
    reasoningEnded: Boolean = false,
) {
    // Nothing to render for a finished block with empty reasoning text.

    // The streaming state deliberately does **not** gate on "text is empty": some
    // upstreams send only `reasoning_content: ""` heartbeats for a long stretch during
    // extended reasoning, with real content only arriving in one burst once the whole
    // thinking phase completes (observed delays of several minutes before the first
    // non-empty chunk). Waiting for non-empty text before rendering would leave the user
    // staring at a blank area for minutes with no way to tell "still thinking" from "stuck".
    // Whether reasoning has actually started is decided by the caller (its
    // streaming-reasoning-active signal); this component doesn't second-guess that --
    // adding a text check here would just swallow the heartbeat signal a second time.
    if (reasoningText.isBlank() && !isStreaming) return

    val colors = OriveoTheme.colors

    // User-driven state: null = follow auto; true/false = pinned by a tap.
    // remember(messageId) resets it to null whenever the message changes.
    var userExpanded: Boolean? by remember(messageId) { mutableStateOf(null) }

    // Automatic state: collapsed even while streaming (autoExpanded is always false) --
    // it no longer renders the full reasoning text expanded during streaming. The
    // collapsed view instead scrolls the latest fragment (reasoningTail) through a
    // fixed single-line window; the user has to tap the chevron/header to see the full text.
    val autoExpanded = false

    val expanded = userExpanded ?: autoExpanded

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ReasoningHeaderRow(
            isStreaming = isStreaming,
            expanded = expanded,
            durationMs = durationMs,
            onToggle = { userExpanded = !expanded },
        )

        // Left-edge 2pt decoration bar: 30% primary while streaming, 20% textTertiary once finished.

        // Implementation note: [MarkdownMessageView] uses BoxWithConstraints internally,
        // which is incompatible with IntrinsicSize.Min/Max. So the bar is self-drawn
        // with drawBehind on the content container to match its height, avoiding a layout crash.
        val decorationColor = if (isStreaming) {
            colors.primary.copy(alpha = 0.3f)
        } else {
            colors.textTertiary.copy(alpha = 0.2f)
        }
        // The content area is always visible: collapsed shows the latest fragment
        // scrolling through a single line, expanded shows the full markdown. The content
        // is its own Composable so frequent reasoning-text mutation during streaming only
        // recomposes here, leaving the header untouched.
        ReasoningContent(
            text = reasoningText,
            isStreaming = isStreaming && !reasoningEnded,
            expanded = expanded,
            decorationColor = decorationColor,
            messageId = messageId,
        )
    }
}

@Composable
private fun ReasoningHeaderRow(
    isStreaming: Boolean,
    expanded: Boolean,
    durationMs: Long?,
    onToggle: () -> Unit,
) {
    val colors = OriveoTheme.colors

    // Label text
    val label = when {
        isStreaming -> stringResource(R.string.reasoning_thinking)
        durationMs != null -> stringResource(
            R.string.reasoning_thought_for,
            formatReasoningDuration(durationMs),
        )
        expanded -> stringResource(R.string.reasoning_hide)
        else -> stringResource(R.string.reasoning_show)
    }

    val stateDesc = if (expanded) "expanded" else "collapsed"

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = true),
                onClick = onToggle,
            )
            .semantics {
                role = Role.Button
                stateDescription = stateDesc
            }
            .padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // Pulsing dot shown only while streaming.
        if (isStreaming) {
            PulsingDot(color = colors.primary)
        }
        // The chevron is always shown -- both streaming and finished states can be tapped to expand/collapse. autoMirrored handles RTL.
        val angle by animateFloatAsState(
            targetValue = if (expanded) 90f else 0f,
            animationSpec = tween(durationMillis = 180, easing = EaseOutCubic),
            label = "chevron_rotate",
        )
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            contentDescription = null,
            // Reading angle inside the graphicsLayer lambda triggers a redraw, not a
            // recomposition; Modifier.rotate(angle) reads State at the parameter level,
            // which would recompose ReasoningHeaderRow every frame.
            modifier = Modifier
                .size(14.dp)
                .graphicsLayer { rotationZ = angle },
            tint = colors.textTertiary,
        )
        Text(
            text = label,
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
}

/**
 * Content sub-Composable, split out so the recomposition scope triggered by frequent
 * reasoningText updates stays isolated here instead of dragging the entire
 * [ReasoningBlock] along with every token.
 *
 * The decoration bar is self-drawn with drawBehind (instead of IntrinsicSize.Min + Row
 * + Box; see the note on [ReasoningBlock]).
 */
@Composable
private fun ReasoningContent(
    text: String,
    isStreaming: Boolean,
    expanded: Boolean,
    decorationColor: Color,
    messageId: String,
) {
    val colors = OriveoTheme.colors
    val density = LocalDensity.current
    // Reasoning is secondary content, so its markdown body/headings/tables all step
    // down to the 15sp tier (the same size used by the collapsed view and the old
    // plain-text state). Code block cards are unaffected -- see the note on LocalMarkdownTextScale.
    val markdownScale = 15f / 17f
    val barWidthPx = with(density) { 2.dp.toPx() }
    val barCornerPx = with(density) { 1.dp.toPx() }
    // The decoration bar's left edge aligns with the parent ReasoningBlock container's
    // left edge (the same alignment line used by the provider badge / typing dots /
    // metadata row); the text start position is the bar width (2dp) plus 8dp of spacing, i.e. 10dp.
    val barLeftInsetPx = with(density) { 10.dp.toPx() }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 10.dp, end = 4.dp, top = 2.dp, bottom = 2.dp)
            .drawBehind {
                // Self-drawn 2pt rounded decoration bar on the left -- height adapts to the text automatically since drawBehind runs after measurement, when size is known.
                drawRoundRect(
                    color = decorationColor,
                    topLeft = Offset(x = -barLeftInsetPx, y = 0f),
                    size = Size(width = barWidthPx, height = size.height),
                    cornerRadius = CornerRadius(barCornerPx, barCornerPx),
                )
            }
            .alpha(0.85f), // slightly lighter than the message body, matching the secondary-text color
    ) {
        if (expanded) {
            // Streaming and finished states share the same markdown rendering path, so
            // there's no visual handoff or jump when streaming settles.
            // The size step-down happens at this shared level so both branches always
            // agree -- there's no risk of "streaming shrank but finished didn't".
            CompositionLocalProvider(LocalMarkdownTextScale provides markdownScale) {
                if (isStreaming) {
                    // Both cost-control tricks live in ReasoningBlockSplitter, keeping
                    // this at O(total input) rather than O(input^2):
                    // (1) closed-off paragraphs are split into immutable blocks, each
                    //     parsed once via remember and free to recompose afterward;
                    // (2) only the trailing active paragraph is re-parsed every frame,
                    //     and even that goes through reasoningSafePrefix first to strip
                    //     any unclosed syntax.
                    // Everything here renders through the isStreaming=false static path,
                    // so it isn't throttled by the typewriter pacer (capped at roughly
                    // 120 characters/second elsewhere) and doesn't depend on a "reasoning
                    // has ended" signal -- settled is always true, so the height floor is
                    // never stuck waiting on the body to keep writing.
                    val splitter = remember(messageId) { ReasoningBlockSplitter() }
                    val split = splitter.advance(text)
                    val safeTail = remember(split.tail) { reasoningSafePrefix(split.tail) }
                    Column(modifier = Modifier.fillMaxWidth()) {
                        split.blocks.forEachIndexed { index, block ->
                            // Keyed by index: the block list only ever appends, existing blocks are never reordered or rewritten.
                            key(index) {
                                MarkdownMessageView(
                                    text = block.trimEnd('\n'),
                                    isStreaming = false,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }
                        if (safeTail.isNotBlank()) {
                            MarkdownMessageView(
                                text = safeTail,
                                isStreaming = false,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                } else {
                    // Expanded + finished: the full markdown, through the same cached render path used for the message body.
                    MarkdownMessageView(
                        text = text,
                        isStreaming = false,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        } else {
            // Collapsed: a fixed single line shows the latest fragment, refreshed as tokens stream in.

            // Critically, maxLines=1 alone isn't enough to hold the height constant --
            // it only guarantees "one line"; that one line's actual rendered height can
            // still shift chunk to chunk depending on the trailing glyphs (mixed
            // scripts, font fallback, ascenders/descenders), pushing the answer below it
            // (or the whole cell) up and down -- which is what reads to the user as "the
            // reasoning area keeps jittering". So the content area is pinned to a fixed
            // single-line height (matching chatBody's nominal line height, so nothing
            // gets clipped), keeping the reasoning block's height perfectly constant.
            val singleLineHeight = with(density) {
                OriveoTheme.typography.chatBody.lineHeight.toDp()
            }
            // An empty string from reasoningTail means this frame's trailing line is
            // just markdown scaffolding (`**` / `###` / `|---|`) or pure whitespace, with
            // no readable content. Keep the previous frame instead of showing blank --
            // otherwise, right when the model emits a markdown marker before the next
            // chunk's actual text, the preview line would flash empty for a moment.
            // No need for a State holder here: every text change already triggers a recomposition of this scope.
            val lastTail = remember(messageId) { arrayOf("") }
            val rawTail = reasoningTail(text)
            if (rawTail.isNotEmpty()) lastTail[0] = rawTail
            val tail = rawTail.ifEmpty { lastTail[0] }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(singleLineHeight),
                contentAlignment = Alignment.CenterStart,
            ) {
                Text(
                    text = tail,
                    style = OriveoTheme.typography.chatBody.copy(fontSize = 15.sp),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Clip,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun PulsingDot(color: Color) {
    val transition = rememberInfiniteTransition(label = "reasoning_dot_pulse")
    val alpha by transition.animateFloat(
        initialValue = 0.4f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 800, easing = EaseOutCubic),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "reasoning_dot_alpha",
    )
    Box(
        modifier = Modifier
            .size(7.dp)

            .graphicsLayer { this.alpha = alpha }
            .background(color, CircleShape),
    )
}

internal fun formatReasoningDuration(durationMs: Long): String {
    val d = max(0L, durationMs)
    if (d < 1000L) return "<1s"
    val totalSeconds = d / 1000L
    if (totalSeconds < 60L) return "${totalSeconds}s"
    val minutes = totalSeconds / 60L
    val seconds = totalSeconds % 60L
    return "${minutes}m ${seconds}s"
}
