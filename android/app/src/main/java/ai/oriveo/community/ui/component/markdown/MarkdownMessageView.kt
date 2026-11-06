package ai.oriveo.community.ui.component.markdown

import androidx.collection.LruCache
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.TextStyle
import ai.oriveo.community.ui.util.contentLayoutDirection
import ai.oriveo.community.ui.util.userContentTextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.ui.component.coerceHeightConstraintPx
import ai.oriveo.community.R
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager
import ai.oriveo.community.ui.component.streaming.StreamingRevealState
import ai.oriveo.community.ui.component.streaming.rememberStreamingReveal
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlin.math.roundToInt

/**
 * Markdown message rendering, aligned with iOS MarkdownMessageView
 *
 * Split into streaming and static paths based on isStreaming.
 * Supports: headings, bold, italic, inline code, code blocks, links,
 *        block quotes, lists, tables, horizontal rules.
 */
/**
 * Wraps in SelectionContainer only when text is selectable; read-only cases render directly (so long-press gestures are not stolen).
 * When [onSaveSelection] is non-null (assistant body only), injects "Save as note" into the selection toolbar (aligned with iOS).
 * When [onReplaceSelection] is non-null (opened from a note), additionally injects "Replace current note".
 */
@Composable
private fun MaybeSelectable(
    selectable: Boolean,
    onSaveSelection: ((String) -> Unit)? = null,
    onAskSelection: ((String) -> Unit)? = null,
    onReplaceSelection: ((String) -> Unit)? = null,
    onSelectionToolbarVisibleChange: (Boolean) -> Unit = {},
    onSelectionGestureActiveChange: (Boolean) -> Unit = {},
    content: @Composable () -> Unit,
) {
    if (!selectable) {
        content()
        return
    }
    val selectionModifier = Modifier.selectionGestureGuard(onSelectionGestureActiveChange)
    if (onSaveSelection != null || onAskSelection != null) {
        val toolbar = rememberNoteSelectionTextToolbar(
            onSaveSelection = onSaveSelection ?: {},
            onAskSelection = onAskSelection,
            onReplaceSelection = onReplaceSelection,
            onVisibilityChange = onSelectionToolbarVisibleChange,
        )
        CompositionLocalProvider(LocalTextToolbar provides toolbar) {
            SelectionContainer(modifier = selectionModifier) { content() }
        }
    } else {
        SelectionContainer(modifier = selectionModifier) { content() }
    }
}

private fun Modifier.selectionGestureGuard(onActiveChange: (Boolean) -> Unit): Modifier = pointerInput(onActiveChange) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        onActiveChange(true)
        try {
            waitForUpOrCancellation(pass = PointerEventPass.Initial)
        } finally {
            onActiveChange(false)
        }
    }
}

/**
 * Font-size scale for markdown body text. 1f = chat body default (chatBody 17sp).
 *
 * Why CompositionLocal rather than a textStyle parameter on [MarkdownMessageView]: font sizes are spread across
 * a dozen-plus places in this file (body / quote / list / paragraph / heading / table cell); threading a parameter through each is verbose
 * and easy to miss one; a missed spot mixes font sizes within the same content, which is worse than not scaling at all.
 *
 * Use: secondary content such as thinking blocks steps down one level (iOS applies -1pt to all markdown output, Web overrides
 * `--o-text-base`; same design intent on all three platforms). Code block cards are not affected: they have their own typographic semantics
 * (monospace font + card background + aligned line numbers); scaling them would also require adjusting the header pill size to stay balanced,
 * and they are already visually separate blocks, so a different font size does not look out of place.
 *
 * Uses [staticCompositionLocalOf]: the value is constant within a subtree, so reading it does not need to establish a subscription.
 */
val LocalMarkdownTextScale = staticCompositionLocalOf { 1f }

/** Scaled body style with content direction, remembered per (base, scale). */
@Composable
private fun markdownBodyStyle(): TextStyle {
    val scale = LocalMarkdownTextScale.current
    // Assistant text follows its own content direction (see userContentTextStyle).
    val base = OriveoTheme.typography.chatBody
    return remember(base, scale) {
        val scaled = if (scale == 1f) base else base.copy(fontSize = base.fontSize * scale, lineHeight = base.lineHeight * scale)
        scaled.merge(userContentTextStyle)
    }
}

/** Scaled table cell style. */
@Composable
private fun markdownCaptionStyle(): TextStyle {
    val scale = LocalMarkdownTextScale.current
    val base = OriveoTheme.typography.caption
    return remember(base, scale) {
        val scaled = if (scale == 1f) base else base.copy(fontSize = base.fontSize * scale, lineHeight = base.lineHeight * scale)
        scaled.merge(userContentTextStyle)
    }
}

@Composable
fun MarkdownMessageView(
    text: String,
    modifier: Modifier = Modifier,
    isStreaming: Boolean = false,
    isUserMessage: Boolean = false,
    /**
     * Callback for **actual render completion** (fires once when the reveal pacer catches up, fade ends, and renderStreaming flips to false).
     * Used to bind the "generation complete" haptic to actual on-screen render completion, not backend transfer completion (when transfer completes, defer-finish is still emitting characters,
     * so a long answer could buzz several seconds early, and the user thinks it has finished rendering). Only messages that were streamed fire it; historical static messages do not.
     */
    onRenderSettled: (() -> Unit)? = null,
    /**
     * Reports the real visual render phase, including the defer-finish tail window after transfer completes.
     * Completed-state UI such as the message action row must wait for `false`; it must not trust only the persisted message state.
     */
    onRenderStreamingChanged: ((Boolean) -> Unit)? = null,
    /**
     * Fires once per advance of the **visible** on-screen body text (the pacer commits by block, about 8Hz). Used for the "visible content stalled" timer:
     * while incoming text has arrived and the pacer is still catching up, characters are still appearing on screen, so that period must not count as a stall.
     */
    onVisibleTextAdvanced: (() -> Unit)? = null,
    /**
     * When non-null, the header of settled code blocks shows a "Save as note" pill; tapping passes the whole fenced markdown block back.
     * Code blocks in the streaming tail are not shown (still being generated). Read-only contexts such as note previews pass null (not shown).
     */
    onSaveCodeBlock: ((String) -> Unit)? = null,
    /**
     * When non-null (assistant body only), injects "Save as note" into the selection toolbar; tapping passes back the selected rendered plain text.
     * Mapped back to the source markdown by SelectionSourceMapper before saving as a note (aligned with iOS editMenuForTextIn).
     */
    onSaveSelection: ((String) -> Unit)? = null,
    /** Settled chat messages expose Ask using the copied rendered selection. */
    onAskSelection: ((QuoteSelectionContent) -> Unit)? = null,
    /** When non-null (opened from a note), the selection toolbar additionally injects "Replace current note". */
    onReplaceSelection: ((String) -> Unit)? = null,
    /** Notifies the outer layer to close the whole message menu when the text selection toolbar is shown, avoiding double popups. */
    onSelectionToolbarVisibleChange: (Boolean) -> Unit = {},
    /** When a finger is already down on selectable text, tells the outer layer before ActionMode not to queue opening the whole message menu. */
    onSelectionGestureActiveChange: (Boolean) -> Unit = {},
    /**
     * Whether text selection is allowed (default true). Read-only preview or whole-row tappable cases pass false,
     * so the inner SelectionContainer does not steal long-press gestures and break the outer whole-row tap semantics.
     */
    selectable: Boolean = true,
    /** Editorial heading style (h1 bolder / h2 brand vertical bar / h3 brand color, with heading sizes widened for hierarchy and relaxed paragraph spacing); only notes / source answers pass true, chat stays plain. */
    emphasizedHeadings: Boolean = false,
) {
    val mdColors = MarkdownTheme.colors()

    // The pacer is always held (historical messages snap synchronously, without animation). defer-finish: after streaming ends, if the pacer is still
    // catching up character by character or fading in, keep the streaming render path until it catches up, avoiding a hard cut to static after a partial fade.
    val reveal = rememberStreamingReveal(target = text, isStreaming = isStreaming)
    // everStreamed distinguishes "streaming / has streamed" from "historical messages never streamed": the latter have empty visibleText on the first frame,
    // so they must not be misjudged as "still revealing" and flash through the streaming path; they must render statically right away.
    var everStreamed by remember { mutableStateOf(false) }
    LaunchedEffect(isStreaming) { if (isStreaming) everStreamed = true }
    val renderStreaming = isStreaming ||
        (everStreamed && (reveal.visibleText.length < text.length || reveal.isFading))

    // Render-complete edge: fires once when renderStreaming goes true→false (and it had streamed), at which point the screen has actually emitted the last character and the fade has ended.
    var wasRenderStreaming by remember { mutableStateOf(false) }
    LaunchedEffect(renderStreaming) {
        onRenderStreamingChanged?.invoke(renderStreaming)
        if (wasRenderStreaming && !renderStreaming) onRenderSettled?.invoke()
        wasRenderStreaming = renderStreaming
    }

    if (onVisibleTextAdvanced != null) {
        val latestOnVisibleTextAdvanced = rememberUpdatedState(onVisibleTextAdvanced)
        LaunchedEffect(reveal) {
            snapshotFlow { reveal.visibleText.length }.collect { latestOnVisibleTextAdvanced.value() }
        }
    }

    // Streaming height floor: during renderStreaming (including the defer-finish tail) the markdown content height only grows, released on settle.
    val flooredModifier = modifier.streamingHeightFloor(active = renderStreaming)

    // Always goes through StreamingMarkdownContent (no top-level if swapping component trees between Streaming/Static): when renderStreaming flips false
    // a tree rebuild on that frame makes the new tree's first frame block split / spacer / last-line style differ from the old one → the user perceives a "flash/reflow at the last moment".
    // Instead, when settled the inside degrades (committed = full text, tail empty), keeping component tree identity continuous; committed RenderBlocks are reused +
    // cache hits, and the final segment merges smoothly into the same RenderBlocks tree (streaming and completed states share the canonical render family, red line §12).
    val settled = !renderStreaming
    // Streaming takes the pacer's visibleText (block-level release); settled takes the full text. Pace the raw text first, then normalize LaTeX,
    // so release timestamps map to characters that actually arrived; unclosed formulas are stripped into the tail and fall back to plain text.
    val sourceText = if (settled) text else reveal.visibleText
    val normalized = remember(sourceText, settled) {
        if (settled) {
            normalizeLatexDelimiters(sourceText) to ""
        } else {
            val split = splitClosedAndOpenLatex(sourceText)
            normalizeLatexDelimiters(split.closed) to split.tail
        }
    }
    // System animations off (animation duration scale 0) → skip fade; blocks appear directly at alpha=1, pacing unchanged.
    // Uses isReduceMotionEnabled (the single copy in this repo, with a process-level cache): previously this read Settings.Global itself,
    // so every MarkdownMessageView instance paid one Binder IPC.
    val context = androidx.compose.ui.platform.LocalContext.current
    val fadeDisabled = remember(context) { isReduceMotionEnabled(context) }
    StreamingMarkdownContent(
        text = normalized.first,
        tailText = normalized.second,
        settled = settled,
        mdColors = mdColors,
        isUserMessage = isUserMessage,
        modifier = flooredModifier,
        reveal = reveal,
        fadeReveal = if (fadeDisabled) null else reveal,
        onSaveCodeBlock = onSaveCodeBlock,
        onSaveSelection = onSaveSelection,
        onAskSelection = onAskSelection?.let { callback ->
            { selected -> callback(QuoteSelectionMapper.capture(text, selected)) }
        },
        onReplaceSelection = onReplaceSelection,
        onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
        onSelectionGestureActiveChange = onSelectionGestureActiveChange,
        selectable = selectable,
        emphasizedHeadings = emphasizedHeadings,
    )
}

/**
 * Streaming height floor (aligned with iOS `AssistantMessageCell.streamingHeightFloor`).
 *
 * During streaming the markdown content height **only grows, never shrinks**: when code block/table closing reparse measures shorter, or activeLine→committed reflow makes natural height
 * drop momentarily, clamp to the historical peak height → cell contentSize stays monotonic → ChatScreen's stick-to-bottom follow will not
 * jitter `scrollBy(overflow)` on the "drop then rise" frame. [active] (= renderStreaming, including the defer-finish tail)
 * flipping to false releases it, and the cell returns to its real height.
 *
 * Measuring the "clamped" height guarantees monotonicity: when natural height < floor, heightIn stretches the node to the floor height and onSizeChanged reports the floor height
 * (floor unchanged); when natural height ≥ floor it reports natural height and the floor grows with it. Trade-off: on the frame a rich block closes, the cell briefly keeps blank space, released when streaming ends
 * (same trade-off on iOS/Android).
 */
@Composable
private fun Modifier.streamingHeightFloor(active: Boolean): Modifier {
    val density = LocalDensity.current
    var floorPx by remember { mutableIntStateOf(0) }
    var clampActive by remember { mutableStateOf(false) }
    LaunchedEffect(active) {
        if (active) {
            clampActive = true
        } else {
            // Release one frame late: let settled content finish its first-frame layout first, so "removing heightIn" and "switching to settled render" do not collide in the same frame
            // which would make the cell collapse from the floor peak back to natural height with a flash. Any collapse (if it happens) occurs in the next frame, once settled is stable.
            withFrameNanos { }
            clampActive = false
            floorPx = 0
        }
    }
    if (!clampActive) return this
    return this
        .heightIn(min = with(density) { floorPx.toDp() })
        .onSizeChanged { floorPx = nextStreamingHeightFloor(floorPx, it.height) }
}

/**
 * Streaming height floor recurrence (pure function, easy to unit-test, aligned with iOS `nextStreamingHeightFloor`): take the historical peak → only grows, never shrinks.
 * When natural height drops momentarily (block closing reparse measures shorter), returns the old peak to clamp; when natural height exceeds the peak, it grows with it.
 *
 * Peak first passes through [coerceHeightConstraintPx]: the floor must be fed back into `heightIn(min=)`, and a height outside the range Compose Constraints can represent
 * would make every subsequent measure throw `IllegalArgumentException`.
 */
internal fun nextStreamingHeightFloor(current: Int, measured: Int): Int =
    coerceHeightConstraintPx(maxOf(current, measured))

@Composable
private fun StreamingMarkdownContent(
    text: String,
    tailText: String,
    settled: Boolean,
    mdColors: MarkdownColors,
    isUserMessage: Boolean,
    modifier: Modifier = Modifier,
    reveal: StreamingRevealState,
    fadeReveal: StreamingRevealState?,
    onSaveCodeBlock: ((String) -> Unit)? = null,
    onSaveSelection: ((String) -> Unit)? = null,
    onAskSelection: ((String) -> Unit)? = null,
    onReplaceSelection: ((String) -> Unit)? = null,
    onSelectionToolbarVisibleChange: (Boolean) -> Unit = {},
    onSelectionGestureActiveChange: (Boolean) -> Unit = {},
    selectable: Boolean = true,
    emphasizedHeadings: Boolean = false,
) {
    // When settled (pacer caught up + fade ended), the full text goes into committed and the tail is empty → only StaticMarkdownContent(RenderBlocks) runs,
    // in the same StreamingMarkdownContent tree as the last streaming frame, with no component tree rebuild.
    val split = remember(text, settled) {
        if (settled) {
            StreamingSplitter.SplitResult(committed = text, tail = "")
        } else {
            // Fade gate: the committed region has no alpha overlay, so the boundary must not swallow a tail still fading in (paragraph pause
            // 180ms < fade 0.25s + stagger 0.3s, so \n\n inevitably hits a block just committed at alpha≈0 → transparent characters instantly
            // jump to full. unsettledTailApprox is a frame-independent plain field (reading the frameNanos state would subscribe the whole content area
            // into per-frame recomposition); it lives in raw source space, while text is LaTeX-normalized — normalization only shrinks, never grows,
            // so the delta direction is conservative. The gate only delays advancement by at most the fade window; committed stays monotonic.
            val gate = (text.length - reveal.unsettledTailApprox).coerceAtLeast(0)
            StreamingSplitter.split(text, maxEnd = gate)
        }
    }

    Column(modifier = modifier) {
        // Committed (stable) portion — stable segments already formed into blocks, taking the cache-hit path
        if (split.committed.isNotEmpty()) {
            StaticMarkdownContent(
                text = split.committed,
                mdColors = mdColors,
                isUserMessage = isUserMessage,
                onSaveCodeBlock = onSaveCodeBlock,
                onSaveSelection = onSaveSelection,
                onAskSelection = onAskSelection,
                onReplaceSelection = onReplaceSelection,
                onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
                onSelectionGestureActiveChange = onSelectionGestureActiveChange,
                selectable = selectable,
                emphasizedHeadings = emphasizedHeadings,
            )
        }

        // Tail (streaming) portion — render path chosen by tailKind to avoid half-formed structures flickering
        if (split.tail.isNotEmpty()) {
            // If the tail ends with a "table being generated" (header+separator has arrived), hand the whole segment to the streaming table card to render row by row,
            // avoiding exposing raw `| a | b |` `|---|` source (aligned with iOS splitTailAtTrailingTable).
            val trailingTable = remember(split.tail) { StreamingSplitter.splitTrailingTable(split.tail) }
            // committed↔tail join spacing: matches the inner block spacing of RenderBlocks after settling, removing the "tight then normal" jump.
            // The key uses committed + tail shape (not the full tail text): when committed is unchanged, the tail start / first block type stays stable,
            // avoiding re-running parseBlocks(committed) on every frame as the tail grows character by character (an O(n) scan on long answers drops frames).
            if (split.committed.isNotEmpty()) {
                val seamGap = remember(split.committed, split.tailKind, trailingTable != null) {
                    streamingSeamSpacing(split.committed, split.tail, split.tailKind, trailingTable != null)
                }
                Spacer(modifier = Modifier.height(seamGap))
            }
            if (trailingTable != null) {
                if (trailingTable.beforeTable.isNotBlank()) {
                    // Text before the table may still be inside the fade window: same canonical render as committed + fade overlay.
                    // Base offset from the global end ≈ table region + source length of the open-latex tail (table content settles immediately,
                    // so the deviation only affects alpha phase; styling is always the final state).
                    RenderBlocks(
                        text = trailingTable.beforeTable,
                        mdColors = mdColors,
                        isUserMessage = isUserMessage,
                        fadeReveal = fadeReveal,
                        fadeBaseDistance = trailingTable.tableText.length + tailText.length,
                        onSaveSelection = onSaveSelection,
                        onReplaceSelection = onReplaceSelection,
                        onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
                        onSelectionGestureActiveChange = onSelectionGestureActiveChange,
                        emphasizedHeadings = emphasizedHeadings,
                    )
                }
                StreamingTable(tableText = trailingTable.tableText, mdColors = mdColors)
            } else {
                when (split.tailKind) {
                    StreamingSplitter.TailKind.UnclosedCodeFence -> {
                        val lang = StreamingSplitter.extractLanguage(split.tail)
                        val code = StreamingSplitter.extractCodeAfterFence(split.tail)
                        StreamingCodeBlockCard(
                            code = code,
                            language = lang,
                            mdColors = mdColors,
                        )
                    }
                    StreamingSplitter.TailKind.UnclosedMathBlock,
                    StreamingSplitter.TailKind.UnclosedTable -> {
                        // Half-formed math block → degrades to plain text; once the whole block closes, the committed path renders it in one go.
                        // Tables are already taken over by the streaming card from splitTrailingTable above; what remains here is the "has pipe row but separator not yet arrived"
                        // early state (after the chunker's line-start protocol hold only the drain remnant is left, rarer than the old path).
                        Text(
                            text = split.tail,
                            style = markdownBodyStyle().copy(color = mdColors.text),
                        )
                    }
                    StreamingSplitter.TailKind.Paragraph -> {
                        // Core of block-level commit: the tail text area shares the same canonical block render with committed/completed state
                        // (appears in final state immediately — the chunker guarantees visible contains no unclosed inline span / unsettled line,
                        // headings have the real font size from the first block, closed bold appears whole in final style, with no raw markers at any point).
                        // Fade is only an alpha overlay, layered on blocks at the tail that are still inside the fade window.
                        RenderBlocks(
                            text = split.tail,
                            mdColors = mdColors,
                            isUserMessage = isUserMessage,
                            fadeReveal = fadeReveal,
                            fadeBaseDistance = tailText.length,
                            onSaveSelection = onSaveSelection,
                            onReplaceSelection = onReplaceSelection,
                            onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
                            onSelectionGestureActiveChange = onSelectionGestureActiveChange,
                            emphasizedHeadings = emphasizedHeadings,
                        )
                    }
                }
            }
        }

        // Unclosed math formula (from LaTeX preprocessing splitClosedAndOpenLatex): plain text fallback
        if (tailText.isNotEmpty()) {
            Text(
                text = tailText,
                style = markdownBodyStyle().copy(color = mdColors.text),
            )
        }
    }
}

/**
 * Text-block fade component for block-level commit rendering (replaces the old ActiveLineRenderer/FadeRegionText dual path).
 *
 * [reveal] null = purely static (does not read the frame clock, no recomposition). When non-null, this restartable scope subscribes
 * to [StreamingRevealState.frameNanos] and rebuilds alpha spans every frame — **only the trailing 1-2 blocks that may intersect the fade window
 * get a non-null reveal** (dispatched by RenderBlocks via a frame-independent distance table); the other blocks
 * take the static path with zero recomposition overhead. Blocks mid-fade are wrapped in DisableSelection to avoid the long-press selection handles jittering every frame.
 */
@Composable
private fun FadableAnnotatedText(
    rendered: AnnotatedString,
    style: androidx.compose.ui.text.TextStyle,
    baseColor: Color,
    reveal: StreamingRevealState?,
    distFromRenderedEnd: Int,
    modifier: Modifier = Modifier,
) {
    val segments = remember(rendered) { inlineTextSegments(rendered) }
    if (segments.size == 1) {
        FadableTextSegment(rendered, style, baseColor, reveal, distFromRenderedEnd, modifier)
        return
    }
    Column(modifier = modifier.fillMaxWidth()) {
        for (segment in segments) {
            val distance = distFromRenderedEnd + segment.charsAfter
            FadableTextSegment(
                rendered = segment.text,
                style = style,
                baseColor = baseColor,
                // Same gate as RenderBlocks.revealFor: only the tail subscribes to the frame clock.
                reveal = reveal?.takeIf { distance < it.unsettledTailApprox + 32 },
                distFromRenderedEnd = distance,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun FadableTextSegment(
    rendered: AnnotatedString,
    style: androidx.compose.ui.text.TextStyle,
    baseColor: Color,
    reveal: StreamingRevealState?,
    distFromRenderedEnd: Int,
    modifier: Modifier = Modifier,
) {
    if (reveal == null) {
        ClickableAnnotatedText(rendered, style, modifier)
        return
    }
    // Reads frameNanos: this block rebuilds its alpha spans each frame; after settle, frameNanos stops updating and recomposition stops
    reveal.frameNanos
    val ledger = remember { FadeAlphaLedger() }
    val faded = applyTailFade(rendered, baseColor, reveal, distFromRenderedEnd, ledger)
    DisableSelection {
        ClickableAnnotatedText(faded, style, modifier)
    }
}

/**
 * Render-layer fade alpha ledger: records the highest alpha (8-bit) each rendered character in the block has reached; rendering takes
 * max(computed, ledger) and writes back — **the alpha of characters already on screen never regresses** (the block-commit red line "never write back"
 * expressed at the alpha layer).
 *
 * Why: fade timestamps live in source character space, while rendering happens in the rendered space after marker stripping; approximating via "tail-aligned distance"
 * mapping. At the moment a commit containing markers lands (`**bold**` rendered +4 / source +8), the distance mapping for leading characters in the block
 * shifts as a whole — already full-color characters get mapped to source characters still fading in → alpha drops then rises again = "slight flicker while rendering the current paragraph
 * " (confirmed on a real device 2026-06-11; the early cosmetic judgment in implementation plan §3.4 was wrong). After ledger clamping, mapping error
 * can at most make a few characters end their fade early (one-directional, imperceptible).
 *
 * Lifecycle follows the FadableAnnotatedText instance (remember): when a block migrates to committed it is already fully settled
 * (guaranteed by the fade gate); the ledger is released with the component, with no cross-block state.
 */
internal class FadeAlphaLedger {
    private var maxAlpha = IntArray(0)
    private var length = 0

    /** Defensive: rendered text shrank (block re-split, should not happen in the final-state-on-appearance model) → clear the ledger and restart from computed. */
    fun resetIfShrunk(newLength: Int) {
        if (newLength < length) {
            maxAlpha.fill(0, 0, length)
            length = 0
        }
    }

    fun clamp(index: Int, computed: Int): Int {
        if (index >= maxAlpha.size) grow(index + 1)
        if (index >= length) length = index + 1
        val v = if (computed > maxAlpha[index]) computed else maxAlpha[index]
        maxAlpha[index] = v
        return v
    }

    private fun grow(min: Int) {
        var cap = if (maxAlpha.isEmpty()) 64 else maxAlpha.size
        while (cap < min) cap *= 2
        maxAlpha = maxAlpha.copyOf(cap)
    }
}

/**
 * Overlays alpha spans on characters at the block tail still inside the fade window. The mapping keeps "rendered tail ↔ visibleText tail
 * distance alignment" to look up the staggered timestamp in [StreamingRevealState.alphaFromEnd]; two fixes (to cure the on-device "flicker while rendering the current
 * paragraph" and "inline code pill pops in" issues):
 * 1. Alpha is monotonically clamped via [FadeAlphaLedger] — the mapping phase shift caused by marker commits no longer pulls full-color characters back to translucent
 *    (the root cause of the flicker; see the ledger class comment);
 * 2. Keep the run's own color during fade (aligned with iOS ChunkFadeAnimator's "original color × alpha" semantics) — inline code and other spans carrying their own
 *    color/background multiply alpha by **their own color**, with the background pill fading in together, no longer overwritten by the body base color
 *    and jumping color at the moment of settling. Link styles are applied at the render layer via TextLinkStyles and are not affected by this overlay
 *    (full color shown directly; a known trade-off).
 * Alpha is quantized to 8-bit and consecutive runs are merged by (alpha, foreground, background); fully settled blocks return as-is with zero span overhead.
 */
private fun applyTailFade(
    src: AnnotatedString,
    baseColor: Color,
    reveal: StreamingRevealState,
    distFromRenderedEnd: Int,
    ledger: FadeAlphaLedger,
): AnnotatedString {
    val n = src.length
    if (n == 0) return src
    ledger.resetIfShrunk(n)
    val alphas = IntArray(n)
    var firstUnsettled = -1
    for (i in 0 until n) {
        val computed = (reveal.alphaFromEnd(distFromRenderedEnd + n - 1 - i) * 255f)
            .roundToInt().coerceIn(0, 255)
        val clamped = ledger.clamp(i, computed)
        alphas[i] = clamped
        if (clamped < 255 && firstUnsettled < 0) firstUnsettled = i
    }
    if (firstUnsettled < 0) return src
    return composeFadedSpans(src, baseColor, alphas, firstUnsettled)
}

/** Merges consecutive runs by (alpha, effective foreground, effective background) to output fade spans (pure function, unit-testable). */
internal fun composeFadedSpans(
    src: AnnotatedString,
    baseColor: Color,
    alphas: IntArray,
    firstUnsettled: Int,
): AnnotatedString {
    val n = src.length
    // Effective color table within the not-yet-full-color window: later spans override earlier ones (consistent with AnnotatedString rendering semantics)
    val effColor = arrayOfNulls<Color>(n - firstUnsettled)
    val effBg = arrayOfNulls<Color>(n - firstUnsettled)
    for (range in src.spanStyles) {
        val c = range.item.color
        val bg = range.item.background
        if (c == Color.Unspecified && bg == Color.Unspecified) continue
        val from = maxOf(range.start, firstUnsettled)
        for (j in from until minOf(range.end, n)) {
            if (c != Color.Unspecified) effColor[j - firstUnsettled] = c
            if (bg != Color.Unspecified) effBg[j - firstUnsettled] = bg
        }
    }
    return buildAnnotatedString {
        append(src)
        var i = firstUnsettled
        while (i < n) {
            val a = alphas[i]
            val c = effColor[i - firstUnsettled]
            val bg = effBg[i - firstUnsettled]
            var j = i + 1
            while (
                j < n &&
                alphas[j] == a &&
                effColor[j - firstUnsettled] == c &&
                effBg[j - firstUnsettled] == bg
            ) {
                j++
            }
            if (a < 255) {
                val alpha = a / 255f
                val fg = c ?: baseColor
                addStyle(
                    SpanStyle(
                        color = fg.copy(alpha = fg.alpha * alpha),
                        background = if (bg != null) bg.copy(alpha = bg.alpha * alpha) else Color.Unspecified,
                    ),
                    i,
                    j,
                )
            }
            i = j
        }
    }
}

@Composable
internal fun StaticMarkdownContent(
    text: String,
    mdColors: MarkdownColors,
    isUserMessage: Boolean,
    modifier: Modifier = Modifier,
    onSaveCodeBlock: ((String) -> Unit)? = null,
    onSaveSelection: ((String) -> Unit)? = null,
    onAskSelection: ((String) -> Unit)? = null,
    onReplaceSelection: ((String) -> Unit)? = null,
    onSelectionToolbarVisibleChange: (Boolean) -> Unit = {},
    onSelectionGestureActiveChange: (Boolean) -> Unit = {},
    selectable: Boolean = true,
    emphasizedHeadings: Boolean = false,
) {
    RenderBlocks(
        text = text,
        mdColors = mdColors,
        isUserMessage = isUserMessage,
        modifier = modifier,
        onSaveCodeBlock = onSaveCodeBlock,
        onSaveSelection = onSaveSelection,
        onAskSelection = onAskSelection,
        onReplaceSelection = onReplaceSelection,
        onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
        onSelectionGestureActiveChange = onSelectionGestureActiveChange,
        selectable = selectable,
        emphasizedHeadings = emphasizedHeadings,
    )
}

/**
 * Long-text chunking: splits the blocks parsed from [text] into segments of at most [maxBlocksPerChunk] blocks each (block index ranges).
 *
 * When the whole article goes into one non-lazy Column, the first frame must compose and measure every block; cost grows linearly with length (
 * Robolectric measured 1801 lines at about 1s and 28.8k lines at 2–2.6s). Callers pass each segment as one LazyColumn item to
 * [MarkdownBlockRangeView], which composes only visible segments.
 */
fun markdownBlockChunks(text: String, maxBlocksPerChunk: Int = MARKDOWN_BLOCKS_PER_CHUNK): List<IntRange> {
    require(maxBlocksPerChunk > 0)
    val count = if (text.isBlank()) 0 else MarkdownRenderCache.blockEntries(normalizeLatexDelimiters(text)).size
    return (0 until count step maxBlocksPerChunk).map { start -> start until minOf(start + maxBlocksPerChunk, count) }
}

const val MARKDOWN_BLOCKS_PER_CHUNK = 8

/**
 * Renders only the [blockRange] segment of [text] (one item of [markdownBlockChunks]); layout and block spacing match [MarkdownMessageView]
 * settled state block for block. When [selectable] is false this segment has no selection of its own; the caller wraps one
 * SelectionContainer around the outside instead (as note details do, so selection can span segments).
 */
@Composable
fun MarkdownBlockRangeView(
    text: String,
    blockRange: IntRange,
    modifier: Modifier = Modifier,
    emphasizedHeadings: Boolean = false,
    selectable: Boolean = true,
) {
    val normalized = remember(text) { normalizeLatexDelimiters(text) }
    RenderBlocks(
        text = normalized,
        mdColors = MarkdownTheme.colors(),
        isUserMessage = false,
        modifier = modifier,
        selectable = selectable,
        emphasizedHeadings = emphasizedHeadings,
        blockRange = blockRange,
    )
}

/**
 * Splits Markdown text into blocks and renders them block by block.
 *
 * Block types: code block, heading, block quote, list, table, hr, paragraph.
 *
 * [fadeReveal] non-null = streaming tail region: blocks at the end still inside the fade window get an alpha overlay (block-level commit rendering,
 * layout and style are final from first appearance, fade only touches alpha). Whether a block needs to subscribe to the frame clock is determined by a **frame-independent** distance table
 * : the block's distance from the global rendered end (approximate cumulative length of subsequent blocks + [fadeBaseDistance]) is less than
 * unsettledTailApprox (a plain field) passes reveal into [FadableAnnotatedText] — per-frame recomposition is limited to
 * the last 1-2 blocks, the rest have zero overhead. Tables/code/math/hr blocks do not fade per character (cards appear as a whole, aligned with iOS).
 */
@Composable
private fun RenderBlocks(
    text: String,
    mdColors: MarkdownColors,
    isUserMessage: Boolean,
    modifier: Modifier = Modifier,
    fadeReveal: StreamingRevealState? = null,
    fadeBaseDistance: Int = 0,
    onSaveCodeBlock: ((String) -> Unit)? = null,
    onSaveSelection: ((String) -> Unit)? = null,
    onAskSelection: ((String) -> Unit)? = null,
    onReplaceSelection: ((String) -> Unit)? = null,
    onSelectionToolbarVisibleChange: (Boolean) -> Unit = {},
    onSelectionGestureActiveChange: (Boolean) -> Unit = {},
    selectable: Boolean = true,
    emphasizedHeadings: Boolean = false,
    /** Renders only this segment of blocks (indices refer to the full-text parse result); null = all. The spacing before the segment's first block matches full-article rendering. */
    blockRange: IntRange? = null,
) {
    val entries = rememberMarkdownBlockEntries(text)

    // Frame-independent fade dispatch: distance is approximated by source length (deviations from inline markers / inter-block separators are at alpha-phase level and do not affect styling)
    val fadeDistances: IntArray? = if (fadeReveal != null && entries.isNotEmpty()) {
        IntArray(entries.size).also { dists ->
            var acc = fadeBaseDistance
            for (i in entries.indices.reversed()) {
                dists[i] = acc
                acc += blockSourceLengthApprox(entries[i].block) + 1
            }
        }
    } else {
        null
    }
    val unsettledTail = fadeReveal?.unsettledTailApprox ?: 0
    fun revealFor(index: Int): StreamingRevealState? {
        val dists = fadeDistances ?: return null
        return if (dists[index] < unsettledTail + 32) fadeReveal else null
    }

    MaybeSelectable(
        selectable = selectable,
        onSaveSelection = onSaveSelection,
        onAskSelection = onAskSelection,
        onReplaceSelection = onReplaceSelection,
        onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
        onSelectionGestureActiveChange = onSelectionGestureActiveChange,
    ) {
        Column(modifier = modifier) {
            entries.forEachIndexed { index, entry ->
                if (blockRange != null && index !in blockRange) return@forEachIndexed
                if (index > 0) {
                    val gap = spacerHeightBetween(
                        prev = entries[index - 1].block,
                        curr = entry.block,
                        blankLinesBetween = entry.gapBefore,
                        emphasized = emphasizedHeadings,
                    )
                    Spacer(modifier = Modifier.height(gap))
                }

                when (val block = entry.block) {
                    is MarkdownBlock.CodeBlock -> {
                        CodeBlockCard(
                            code = block.code,
                            language = block.language,
                            mdColors = mdColors,
                            onSaveAsNote = onSaveCodeBlock,
                        )
                    }

                    is MarkdownBlock.Heading -> {
                        // Aligned with iOS: markdown headings inside messages reuse the chatBody system sans-serif font, adjusting only size and weight.
                        // Chat tier: H1=23pt Bold, H2=19pt Bold, H3-H6=17pt SemiBold (aligned with iOS MarkdownAttributedStringRenderer).
                        // Editorial tier (notes / source answers) widens hierarchy: H1=26pt ExtraBold, H2=21pt Bold (+ left brand vertical bar), H3=18pt SemiBold (brand color).
                        // Under block-level commit, headings appear at their real font size from the first block (canonical), and fade only touches alpha.
                        val (headingBaseSize, headingWeight) = if (emphasizedHeadings) {
                            when (block.level) {
                                1 -> 26.sp to FontWeight.ExtraBold
                                2 -> 21.sp to FontWeight.Bold
                                else -> 18.sp to FontWeight.SemiBold
                            }
                        } else {
                            when (block.level) {
                                1 -> 23.sp to FontWeight.Bold
                                2 -> 19.sp to FontWeight.Bold
                                else -> 17.sp to FontWeight.SemiBold
                            }
                        }
                        // Heading font sizes come from an independent constant table (not derived from chatBody), so they must explicitly follow
                        // LocalMarkdownTextScale — otherwise in secondary content the body shrinks while headings do not, mixing sizes.
                        val headingScale = LocalMarkdownTextScale.current
                        val headingSize =
                            if (headingScale == 1f) headingBaseSize else headingBaseSize * headingScale
                        // Editorial tier h3+ uses brand color; the rest inherit body color. Color must be passed explicitly: BasicText for
                        // Color.Unspecified falls back to hard-coded Color.Black, which causes black text in dark mode.
                        val headingColor =
                            if (emphasizedHeadings && block.level >= 3) OriveoTheme.colors.primary else mdColors.text
                        val style = markdownBodyStyle().copy(
                            color = headingColor,
                            fontSize = headingSize,
                            fontWeight = headingWeight,
                            lineHeight = headingSize * 1.3f,
                        )
                        val headingText = @Composable {
                            FadableAnnotatedText(
                                rendered = rememberRenderedInlineMarkdown(block.text, mdColors),
                                style = style,
                                baseColor = headingColor,
                                reveal = revealFor(index),
                                distFromRenderedEnd = fadeDistances?.get(index) ?: 0,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        if (emphasizedHeadings && block.level == 2) {
                            // Editorial section heading: left brand-colored vertical bar (4dp wide / 2dp corner radius / 10dp gap from text)
                            Row(
                                modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Min),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Box(
                                    modifier = Modifier
                                        .width(4.dp)
                                        .fillMaxHeight()
                                        .clip(RoundedCornerShape(2.dp))
                                        .background(OriveoTheme.colors.primary),
                                )
                                Spacer(modifier = Modifier.width(10.dp))
                                headingText()
                            }
                        } else {
                            headingText()
                        }
                    }

                    is MarkdownBlock.BlockQuote -> {
                        Row(modifier = Modifier.fillMaxWidth()) {
                            Spacer(
                                modifier = Modifier
                                    .width(3.dp)
                                    .height(20.dp)
                                    .clip(RoundedCornerShape(2.dp))
                                    .background(mdColors.quoteBorder),
                            )
                            Spacer(modifier = Modifier.width(OriveoTheme.spacing.md))
                            FadableAnnotatedText(
                                rendered = rememberRenderedInlineMarkdown(block.text, mdColors),
                                style = markdownBodyStyle().copy(color = mdColors.quoteText),
                                baseColor = mdColors.quoteText,
                                reveal = revealFor(index),
                                distFromRenderedEnd = fadeDistances?.get(index) ?: 0,
                            )
                        }
                    }

                    is MarkdownBlock.ListItem -> {
                        // The bullet row follows the item's own direction, so an English item under
                        // an RTL locale keeps its bullet at the line start.
                        CompositionLocalProvider(
                            LocalLayoutDirection provides contentLayoutDirection(
                                block.text,
                                LocalLayoutDirection.current,
                            ),
                        ) {
                            Row(modifier = Modifier.fillMaxWidth()) {
                                Text(
                                    text = block.bullet,
                                    style = markdownBodyStyle(),
                                    color = mdColors.textSecondary,
                                    modifier = Modifier.width(20.dp),
                                )
                                FadableAnnotatedText(
                                    rendered = rememberRenderedInlineMarkdown(block.text, mdColors),
                                    style = markdownBodyStyle().copy(color = mdColors.text),
                                    baseColor = mdColors.text,
                                    reveal = revealFor(index),
                                    distFromRenderedEnd = fadeDistances?.get(index) ?: 0,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }

                    is MarkdownBlock.Table -> {
                        MarkdownTable(
                            headers = block.headers,
                            rows = block.rows,
                            mdColors = mdColors,
                        )
                    }

                    is MarkdownBlock.HorizontalRule -> {
                        HorizontalDivider(color = mdColors.tableBorder)
                    }

                    is MarkdownBlock.Paragraph -> {
                        // Inline formulas prefer the inlineContent placeholder path, laid out on the same line as text.
                        // Paragraphs with formulas get no fade overlay (alpha spans do not apply to InlineTextContent,
                        // the placeholder image appears as a whole — an acceptable trade-off, same class as cards).
                        if (block.text.contains('$') && extractInlineMath(block.text).isNotEmpty()) {
                            ParagraphWithInlineMath(
                                text = block.text,
                                mdColors = mdColors,
                            )
                        } else {
                            FadableAnnotatedText(
                                rendered = rememberRenderedInlineMarkdown(block.text, mdColors),
                                style = markdownBodyStyle().copy(color = mdColors.text),
                                baseColor = mdColors.text,
                                reveal = revealFor(index),
                                distFromRenderedEnd = fadeDistances?.get(index) ?: 0,
                            )
                        }
                    }

                    is MarkdownBlock.MathBlock -> {
                        MathBlockView(
                            latex = block.latex,
                            mdColors = mdColors,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }
    }
}

/** Block source-length approximation for the fade distance table (marker/inline deviations are alpha-phase level); card-type blocks settle immediately and count as 0. */
private fun blockSourceLengthApprox(block: MarkdownBlock): Int = when (block) {
    is MarkdownBlock.Paragraph -> block.text.length
    is MarkdownBlock.Heading -> block.text.length
    is MarkdownBlock.BlockQuote -> block.text.length
    is MarkdownBlock.ListItem -> block.text.length
    else -> 0
}

/**
 * Renders a Paragraph containing inline math formulas.
 *
 * Takes the `Text(annotatedString, inlineContent = ...)` path; URL links go through LinkAnnotation.Url
 * handled natively by Text (same as ClickableAnnotatedText), so math and links can coexist and both be tappable.
 */
@Composable
private fun ParagraphWithInlineMath(
    text: String,
    mdColors: MarkdownColors,
) {
    val style = markdownBodyStyle().copy(color = mdColors.text)
    val context = LocalContext.current
    val withMath = remember(text, mdColors) { renderInlineMarkdownWithMath(text, mdColors) }
    val snackbar = rememberGlobalSnackbarManager()
    val annotated = remember(withMath, context, snackbar) { withMath.annotated.withSafeLinkHandling(context, snackbar) }
    val inlineContent = buildInlineMathContent(
        spans = withMath.mathSpans,
        style = style,
        colors = mdColors,
    )
    val segments = remember(annotated) { inlineTextSegments(annotated) }
    Column(modifier = Modifier.fillMaxWidth()) {
        for (segment in segments) {
            Text(
                text = segment.text,
                style = style,
                inlineContent = inlineContent,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun ClickableAnnotatedText(
    text: AnnotatedString,
    style: androidx.compose.ui.text.TextStyle,
    modifier: Modifier = Modifier,
) {
    // Link clicks are handled natively by Text via LinkAnnotation.Url inside AnnotatedString (replacing the deprecated
    // ClickableText, whose pointerInput keys the onClick lambda; per-frame recomposition during streaming fade would repeatedly restart
    // gesture detection and interrupt in-progress taps). Wrapped in a safe listener: openUri throws on malformed URLs produced by the LLM.
    val context = LocalContext.current
    val snackbar = rememberGlobalSnackbarManager()
    val safeText = remember(text, context, snackbar) { text.withSafeLinkHandling(context, snackbar) }
    Text(
        text = safeText,
        style = style,
        modifier = modifier,
    )
}

/** Injects an exception-catching click listener into LinkAnnotation.Url (malformed URLs do not crash). Returns as-is when there are no links. */
private fun AnnotatedString.withSafeLinkHandling(
    context: android.content.Context,
    snackbar: GlobalSnackbarManager?,
): AnnotatedString {
    if (getLinkAnnotations(0, length).isEmpty()) return this
    return mapAnnotations { range ->
        val link = range.item as? LinkAnnotation.Url ?: return@mapAnnotations range
        val safe = LinkAnnotation.Url(link.url, link.styles) {
            val url = (it as LinkAnnotation.Url).url
            if (!openExternalUrl(context, url)) {
                snackbar?.show(
                    GlobalSnackbarMessage(
                        UiText.Resource(R.string.link_open_failed_message),
                        style = GlobalToastStyle.Error,
                    ),
                )
            }
        }
        @Suppress("UNCHECKED_CAST")
        (range as AnnotatedString.Range<AnnotatedString.Annotation>).copy(item = safe)
    }
}

/**
 * Streaming table row-by-row card — aligned with iOS UIKitStreamingTableCard.
 *
 * Input is the table region text cut by [StreamingSplitter.splitTrailingTable] (header + separator + data rows, including the row being typed),
 * rendered with the same [MarkdownTable] as static tables: it is a table as soon as header+separator arrive, data rows grow line by line, and the row being typed
 * grows character by character inside the table as a partial data row, **never exposing raw `| a | b |` source**. Column widths are split evenly by column count via [resolveMarkdownTableLayout]
 * (independent of content), so appending rows does not reflow existing rows. After the table closes it moves into committed, still using [MarkdownTable], so the switch causes no jump.
 *
 * Parsing matches the table branch of [parseBlocksWithGaps] 1:1 (header = row 0, separator = row 1 dropped, data = drop(2)).
 * When the separator is not yet complete (fewer than 2 rows parse), it degrades to plain text fallback.
 */
@Composable
private fun StreamingTable(tableText: String, mdColors: MarkdownColors) {
    val parsed = remember(tableText) {
        val tableLines = tableText.split('\n').filter { it.isNotBlank() }
        if (tableLines.size < 2) {
            null
        } else {
            val headers = tableLines[0].split("|").filter { it.isNotBlank() }
            val rows = tableLines.drop(2).map { row -> row.split("|").filter { it.isNotBlank() } }
            if (headers.isEmpty()) null else headers to rows
        }
    }
    if (parsed == null) {
        Text(text = tableText, style = markdownBodyStyle().copy(color = mdColors.text))
    } else {
        MarkdownTable(headers = parsed.first, rows = parsed.second, mdColors = mdColors)
    }
}

@Composable
private fun MarkdownTable(
    headers: List<String>,
    rows: List<List<String>>,
    mdColors: MarkdownColors,
) {
    val borderColor = mdColors.tableBorder
    val borderWidth = OriveoBorderWidth.standard
    // Aligned with iOS UIKitTableCard: corner radius 10, outer border uses border color at 50% alpha, solid card that does not show the page background through
    val shape = RoundedCornerShape(10.dp)
    val colCount = headers.size.coerceAtLeast(1)

    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val layout = remember(maxWidth, colCount) {
            resolveMarkdownTableLayout(
                viewportWidth = maxWidth,
                columnCount = colCount,
            )
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
        ) {
            Column(
                modifier = Modifier
                    .width(layout.tableWidth)
                    .clip(shape)
                    .background(mdColors.tableCellBg)
                    .border(borderWidth, borderColor.copy(alpha = 0.5f), shape),
            ) {
                MarkdownTableRow(
                    cells = headers,
                    columnWidth = layout.columnWidth,
                    mdColors = mdColors,
                    backgroundColor = mdColors.tableHeaderBg,
                    headerFontWeight = FontWeight.SemiBold,
                )

                rows.forEachIndexed { rowIndex, row ->
                    HorizontalDivider(thickness = borderWidth, color = borderColor)
                    MarkdownTableRow(
                        cells = List(colCount) { index -> row.getOrElse(index) { "" } },
                        columnWidth = layout.columnWidth,
                        mdColors = mdColors,
                        // Zebra striping (iOS: data rows 2/4/6… use altRowBg): rowIndex is 0-based → odd rows darkened
                        backgroundColor = if (rowIndex % 2 == 1) mdColors.tableAltRowBg else mdColors.tableCellBg,
                    )
                }
            }
        }
    }
}

@Composable
private fun MarkdownTableRow(
    cells: List<String>,
    columnWidth: Dp,
    mdColors: MarkdownColors,
    backgroundColor: androidx.compose.ui.graphics.Color = androidx.compose.ui.graphics.Color.Transparent,
    headerFontWeight: FontWeight? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(backgroundColor),
    ) {
        cells.forEachIndexed { index, cell ->
            if (index > 0) {
                VerticalDivider(
                    thickness = OriveoBorderWidth.standard,
                    color = mdColors.tableBorder,
                )
            }
            TableCell(
                text = cell,
                mdColors = mdColors,
                fontWeight = headerFontWeight,
                modifier = Modifier.width(columnWidth),
            )
        }
    }
}

@Composable
private fun TableCell(
    text: String,
    mdColors: MarkdownColors,
    fontWeight: FontWeight? = null,
    modifier: Modifier = Modifier,
) {
    val normalized = remember(text) { text.trim() }
    val style = if (fontWeight != null) {
        markdownCaptionStyle().copy(fontWeight = fontWeight, color = mdColors.text)
    } else {
        markdownCaptionStyle().copy(color = mdColors.text)
    }
    val context = LocalContext.current
    // Same inline formula path as Paragraph: `$\\log_a M$` in cells renders to a Bitmap instead of leaking raw source.
    // With no formulas, mathSpans is empty and inlineContent is an empty map, degrading to the original rich-text cells.
    val withMath = remember(normalized, mdColors) { renderInlineMarkdownWithMath(normalized, mdColors) }
    val snackbar = rememberGlobalSnackbarManager()
    val annotated = remember(withMath, context, snackbar) { withMath.annotated.withSafeLinkHandling(context, snackbar) }
    val inlineContent = buildInlineMathContent(
        spans = withMath.mathSpans,
        style = style,
        colors = mdColors,
    )
    Text(
        text = annotated,
        style = style,
        inlineContent = inlineContent,
        modifier = modifier.padding(horizontal = OriveoTheme.spacing.sm, vertical = OriveoTheme.spacing.xs),
    )
}

/**
 * Synchronous path (same as [rememberMarkdownBlockEntries]): on cache miss the first frame already gets rich text with SpanStyle,
 * no longer going through the `stripInlineMarkdownSyntax` plain-text intermediate state — avoiding "**bold** shows unformatted plain first → next frame it turns bold",
 * and "[text](url) shows raw first → next frame a blue underline" paragraph-level refresh jank.
 *
 * A single text segment is usually ≤ 1KB; [MarkdownRenderer.render] takes < 1ms on the main thread, and together with block parsing it still fits the frame budget.
 */
@Composable
private fun rememberRenderedInlineMarkdown(
    text: String,
    mdColors: MarkdownColors,
): AnnotatedString {
    if (!shouldRenderRichInlineMarkdown(text)) {
        return remember(text) { AnnotatedString(text) }
    }
    return remember(text, mdColors) {
        MarkdownRenderCache.renderInline(text, mdColors)
    }
}

private val MarkdownTableMinColumnWidth = 120.dp
private const val MarkdownPrewarmMaxChars = 2_400
private const val MarkdownPrewarmMaxTableLines = 14
private const val MarkdownPrewarmMaxCodeLines = 80

internal data class MarkdownTableLayout(
    val tableWidth: Dp,
    val columnWidth: Dp,
)

internal fun resolveMarkdownTableLayout(
    viewportWidth: Dp,
    columnCount: Int,
    minColumnWidth: Dp = MarkdownTableMinColumnWidth,
): MarkdownTableLayout {
    val resolvedColumnCount = columnCount.coerceAtLeast(1)
    val minTableWidth = minColumnWidth * resolvedColumnCount
    val tableWidth = if (viewportWidth < minTableWidth) {
        minTableWidth
    } else {
        viewportWidth
    }

    return MarkdownTableLayout(
        tableWidth = tableWidth,
        columnWidth = tableWidth / resolvedColumnCount.toFloat(),
    )
}

/**
 * Synchronous path (aligned with iOS: committed segment parsing completes in one go on the main thread, with no cross-frame switch).
 *
 * Why: the old async produceState path returned null on the first frame on cache miss → RenderBlocks took the `Text(plain)` fallback
 * → the Column with block styling only came back after the coroutine finished, so the whole committed segment visually dropped from "markdown styling" to "single-size plain text"
 * and then switched back — heading sizes, code cards, and list bullets were gone; that was the root cause of "the segment flashes after the paragraph settles".
 *
 * During streaming, stablePrefix/committed is usually < 5KB, and [parseBlocksWithGaps] at < 3ms on the main thread is acceptable;
 * a one-time full parse when settled flips true occasionally drops one frame for 10-30ms, but it happens only on the frame where fade ends,
 * when the user's view is already complete and unnoticeable. On LRU hit it is O(1). This buys zero cross-frame visual continuity, far better than the old async path.
 */
@Composable
private fun rememberMarkdownBlockEntries(text: String): List<MarkdownBlockEntry> =
    remember(text) {
        if (text.isBlank()) emptyList() else MarkdownRenderCache.blockEntries(text)
    }

internal fun shouldRenderRichInlineMarkdown(
    text: String,
    trim: Boolean = false,
): Boolean {
    val normalized = if (trim) text.trim() else text
    if (normalized.isEmpty()) return false
    return normalized.contains("**") ||
        normalized.contains("***") ||
        normalized.contains("~~") ||
        normalized.contains('`') ||
        normalized.contains('[') ||
        normalized.contains('*')
}

internal fun shouldPrewarmMarkdown(text: String): Boolean {
    if (text.isBlank()) return false
    if (text.length > MarkdownPrewarmMaxChars) return false

    var tableLineRun = 0
    var maxTableLineRun = 0
    var inCodeBlock = false
    var codeLineCount = 0
    var codeFenceCount = 0

    text.lineSequence().forEach { line ->
        val startIndex = firstNonWhitespaceIndex(line)
        if (startsWithCodeFence(line, startIndex)) {
            codeFenceCount++
            inCodeBlock = !inCodeBlock
            tableLineRun = 0
            return@forEach
        }

        if (inCodeBlock) {
            codeLineCount++
        }

        if (isTableLine(line, startIndex)) {
            tableLineRun++
            if (tableLineRun > maxTableLineRun) {
                maxTableLineRun = tableLineRun
            }
        } else {
            tableLineRun = 0
        }
    }

    if (codeFenceCount > 2) return false
    if (codeLineCount > MarkdownPrewarmMaxCodeLines) return false
    if (maxTableLineRun > MarkdownPrewarmMaxTableLines) return false
    return true
}

// ── Block parsing ──

internal sealed class MarkdownBlock {
    data class CodeBlock(val code: String, val language: String) : MarkdownBlock()
    data class Heading(val text: String, val level: Int) : MarkdownBlock()
    data class BlockQuote(val text: String) : MarkdownBlock()
    data class ListItem(val text: String, val bullet: String) : MarkdownBlock()
    data class Table(val headers: List<String>, val rows: List<List<String>>) : MarkdownBlock()
    data object HorizontalRule : MarkdownBlock()
    data class Paragraph(val text: String) : MarkdownBlock()

    /** Block-level math formula — content wrapped in `$$...$$` within a markdown paragraph. */
    data class MathBlock(val latex: String) : MarkdownBlock()
}

 // Parsed block entry, carrying the number of consecutive blank lines before this block.
 // Used at render time to distinguish "tightly adjacent siblings" (gapBefore=0, compact) from "paragraphs separated by blank lines in the source"
 // (gapBefore>0, loose), so Android's visual hierarchy matches iOS paragraphSpacing.
internal data class MarkdownBlockEntry(
    val block: MarkdownBlock,
    val gapBefore: Int,
)

// ── Block-pair spacing (rendering) ──
//
 // Visual spacing between blocks is determined by (previous block type, current block type, number of blank lines between).
 // Aligned with iOS MarkdownAttributedStringRenderer's paragraphSpacing behavior:
 // iOS treats source blank lines as implicit paragraph spacing (≈ 1em); Android layers on that basis here.
 // Reference: GitHub Markdown / Claude.ai / ChatGPT — paragraph ≈ 16dp, list item 4–10dp,
 // 20dp visual break before a heading, 6dp after it so it sits tight to its content.
internal fun spacerHeightBetween(
    prev: MarkdownBlock,
    curr: MarkdownBlock,
    blankLinesBetween: Int,
    emphasized: Boolean = false,
): Dp {
    val hasBlank = blankLinesBetween > 0
    return when {
        // Visual break before headings (editorial tier uses larger top spacing)
        curr is MarkdownBlock.Heading -> if (emphasized) 28.dp else 20.dp
        // Heading → content: tight to the paragraph it belongs to
        prev is MarkdownBlock.Heading -> 6.dp
        // Between list items: compact / spaced, two tiers
        prev is MarkdownBlock.ListItem && curr is MarkdownBlock.ListItem ->
            if (hasBlank) 10.dp else 4.dp
        // Block containers (code / table / quote / rule / math formula) separated from other content
        prev is MarkdownBlock.CodeBlock || curr is MarkdownBlock.CodeBlock -> 12.dp
        prev is MarkdownBlock.Table || curr is MarkdownBlock.Table -> 12.dp
        prev is MarkdownBlock.BlockQuote || curr is MarkdownBlock.BlockQuote -> 12.dp
        prev is MarkdownBlock.HorizontalRule || curr is MarkdownBlock.HorizontalRule -> 12.dp
        prev is MarkdownBlock.MathBlock || curr is MarkdownBlock.MathBlock -> 12.dp
        // Paragraph ↔ paragraph / cross-block (including paragraph→list / list→paragraph); editorial tier relaxes paragraph spacing
        else -> if (hasBlank) (if (emphasized) 18.dp else 16.dp) else 8.dp
    }
}

/**
 * Spacing at the committed/tail join — uses a value matching the inner block spacing of [RenderBlocks] after settling ([spacerHeightBetween]),
 * removing the jump where "during streaming committed↔tail is tight (0dp) and block spacing only appears after settling" (especially consecutive code blocks 0→12dp).
 *
 * prev = last committed block; curr = first tail block (inferred from tailKind / whether it is a table, avoiding parsing the half-formed structure of an unclosed tail).
 * After settling the tail is empty and this spacing is no longer rendered; inter-block spacing is taken over by [RenderBlocks], so the join is consistent before and after, with no jump.
 */
internal fun streamingSeamSpacing(
    committed: String,
    tail: String,
    tailKind: StreamingSplitter.TailKind,
    tailIsTable: Boolean,
): Dp {
    // Goes through the blockEntries cache: committed is the same string just parsed by StaticMarkdownContent in this frame,
    // so the LRU always hits in O(1) — previously parseBlocks bypassed the cache, which meant a double O(n) full-text parse on the busiest streaming frames.
    val prev = MarkdownRenderCache.blockEntries(committed).lastOrNull()?.block ?: return 0.dp
    val curr: MarkdownBlock = when {
        tailIsTable -> MarkdownBlock.Table(emptyList(), emptyList())
        tailKind == StreamingSplitter.TailKind.UnclosedCodeFence -> MarkdownBlock.CodeBlock("", "")
        tailKind == StreamingSplitter.TailKind.UnclosedMathBlock -> MarkdownBlock.MathBlock("")
        else -> parseBlocks(tail).firstOrNull() ?: MarkdownBlock.Paragraph(tail)
    }
    // Consecutive blank lines at the end of committed → distinguishes compact/loose (code blocks/tables fixed at 12dp, unaffected)
    val trailingNewlines = committed.length - committed.trimEnd('\n').length
    return spacerHeightBetween(prev, curr, (trailingNewlines - 1).coerceAtLeast(0))
}

private data class InlineMarkdownCacheKey(
    val text: String,
    val colors: MarkdownColors,
)

private data class CodeHighlightCacheKey(
    val code: String,
    val language: String,
    val colors: MarkdownColors,
)

internal object MarkdownRenderCache {
    private const val MAX_BLOCK_CACHE_CHARS = 240_000
    private const val MAX_INLINE_CACHE_CHARS = 160_000
    private const val MAX_CODE_CACHE_CHARS = 120_000
    private val blockCacheLock = Any()
    private val inlineCacheLock = Any()
    private val codeCacheLock = Any()

    private val blockEntriesCache = object : LruCache<String, List<MarkdownBlockEntry>>(MAX_BLOCK_CACHE_CHARS) {
        override fun sizeOf(key: String, value: List<MarkdownBlockEntry>): Int = key.length.coerceAtLeast(1)
    }

    private val inlineCache = object : LruCache<InlineMarkdownCacheKey, AnnotatedString>(MAX_INLINE_CACHE_CHARS) {
        override fun sizeOf(key: InlineMarkdownCacheKey, value: AnnotatedString): Int =
            key.text.length.coerceAtLeast(1)
    }

    private val codeCache = object : LruCache<CodeHighlightCacheKey, AnnotatedString>(MAX_CODE_CACHE_CHARS) {
        override fun sizeOf(key: CodeHighlightCacheKey, value: AnnotatedString): Int =
            key.code.length.coerceAtLeast(1)
    }

    fun blockEntries(text: String): List<MarkdownBlockEntry> {
        if (text.isBlank()) return emptyList()
        synchronized(blockCacheLock) {
            blockEntriesCache.get(text)?.let { return it }
        }

        val parsed = parseBlocksWithGaps(text)
        synchronized(blockCacheLock) {
            blockEntriesCache.get(text)?.let { return it }
            blockEntriesCache.put(text, parsed)
        }
        return parsed
    }

    fun cachedBlockEntries(text: String): List<MarkdownBlockEntry>? =
        if (text.isBlank()) {
            emptyList()
        } else {
            synchronized(blockCacheLock) {
                blockEntriesCache.get(text)
            }
        }

    fun blocks(text: String): List<MarkdownBlock> = blockEntries(text).map { it.block }

    fun cachedBlocks(text: String): List<MarkdownBlock>? =
        cachedBlockEntries(text)?.map { it.block }

    fun renderInline(
        text: String,
        colors: MarkdownColors,
        trim: Boolean = false,
    ): AnnotatedString {
        val normalized = if (trim) text.trim() else text
        val key = InlineMarkdownCacheKey(normalized, colors)
        synchronized(inlineCacheLock) {
            inlineCache.get(key)?.let { return it }
        }

        val rendered = MarkdownRenderer.render(normalized, colors)
        synchronized(inlineCacheLock) {
            inlineCache.get(key)?.let { return it }
            inlineCache.put(key, rendered)
        }
        return rendered
    }

    fun cachedInline(
        text: String,
        colors: MarkdownColors,
        trim: Boolean = false,
    ): AnnotatedString? {
        val normalized = if (trim) text.trim() else text
        val key = InlineMarkdownCacheKey(normalized, colors)
        return synchronized(inlineCacheLock) {
            inlineCache.get(key)
        }
    }

    fun highlightCode(
        code: String,
        language: String,
        colors: MarkdownColors,
    ): AnnotatedString {
        val key = CodeHighlightCacheKey(code, language, colors)
        synchronized(codeCacheLock) {
            codeCache.get(key)?.let { return it }
        }

        val highlighted = SyntaxHighlighter.highlight(code, language, colors)
        synchronized(codeCacheLock) {
            codeCache.get(key)?.let { return it }
            codeCache.put(key, highlighted)
        }
        return highlighted
    }

    fun cachedHighlightedCode(
        code: String,
        language: String,
        colors: MarkdownColors,
    ): AnnotatedString? {
        val key = CodeHighlightCacheKey(code, language, colors)
        return synchronized(codeCacheLock) {
            codeCache.get(key)
        }
    }

    fun prewarm(
        text: String,
        colors: MarkdownColors,
    ) {
        blocks(text).forEach { block ->
            when (block) {
                is MarkdownBlock.BlockQuote -> renderInline(block.text, colors)
                is MarkdownBlock.ListItem -> renderInline(block.text, colors)
                is MarkdownBlock.Paragraph -> renderInline(block.text, colors)
                is MarkdownBlock.Table -> {
                    block.headers.forEach { renderInline(it, colors, trim = true) }
                    block.rows.forEach { row ->
                        row.forEach { renderInline(it, colors, trim = true) }
                    }
                }
                is MarkdownBlock.CodeBlock -> highlightCode(block.code, block.language, colors)
                is MarkdownBlock.MathBlock -> Unit // Block math rendering is triggered asynchronously in the UI layer; after a cache hit, the next appearance opens instantly
                is MarkdownBlock.Heading, MarkdownBlock.HorizontalRule -> Unit
            }
        }
    }
}

private fun firstNonWhitespaceIndex(line: String): Int {
    for (index in line.indices) {
        if (!line[index].isWhitespace()) return index
    }
    return -1
}

private fun lastNonWhitespaceExclusive(line: String): Int {
    var end = line.length
    while (end > 0 && line[end - 1].isWhitespace()) {
        end--
    }
    return end
}

private fun isHorizontalRule(
    line: String,
    startIndex: Int = firstNonWhitespaceIndex(line),
    endExclusive: Int = lastNonWhitespaceExclusive(line),
): Boolean {
    if (startIndex < 0) return false
    val length = endExclusive - startIndex
    if (length < 3) return false

    val marker = line[startIndex]
    if (marker != '-' && marker != '*' && marker != '_') return false

    for (index in startIndex + 1 until endExclusive) {
        if (line[index] != marker) return false
    }
    return true
}

private fun startsWithCodeFence(line: String, startIndex: Int): Boolean =
    startIndex >= 0 &&
        startIndex + 2 < line.length &&
        line[startIndex] == '`' &&
        line[startIndex + 1] == '`' &&
        line[startIndex + 2] == '`'

private fun isBlockQuoteLine(line: String): Boolean =
    line.length >= 2 && line[0] == '>' && line[1].isWhitespace()

private fun isTableLine(line: String, startIndex: Int): Boolean =
    startIndex >= 0 && line[startIndex] == '|'

/**
 * Checks whether a line begins a block math segment starting with `$$`.
 * Note: avoid also counting inline-class forms that have characters after `$$` and close with `$$` (e.g. single-line `$$x$$`) as block-level —
 * this "single-line $$x$$" form is also block-level and is still recognized by this helper.
 */
private fun startsWithBlockMathFence(line: String, startIndex: Int): Boolean =
    startIndex >= 0 &&
        startIndex + 1 < line.length &&
        line[startIndex] == '$' &&
        line[startIndex + 1] == '$'

private fun parseUnorderedListContent(line: String, startIndex: Int): String? {
    if (startIndex < 0 || startIndex + 1 >= line.length) return null
    val marker = line[startIndex]
    if (marker != '-' && marker != '*' && marker != '+') return null
    if (!line[startIndex + 1].isWhitespace()) return null
    return line.substring(startIndex + 2).trimStart()
}

/**
 * CommonMark §5.2: a list item may interrupt a paragraph (no blank line needed) when it is
 * non-empty, indented < 4 columns, and — for ordered lists — starts at 1.
 */
private fun canInterruptParagraphAsList(line: String, startIndex: Int): Boolean {
    if (startIndex !in 0..3) return false
    val unordered = parseUnorderedListContent(line, startIndex)
    if (unordered != null) return unordered.isNotBlank()
    val ordered = parseOrderedListItem(line, startIndex) ?: return false
    return ordered.first == "1." && ordered.second.isNotBlank()
}

private fun parseOrderedListItem(line: String, startIndex: Int): Pair<String, String>? {
    if (startIndex < 0 || !line[startIndex].isDigit()) return null

    var index = startIndex
    while (index < line.length && line[index].isDigit()) {
        index++
    }

    if (index == startIndex || index + 1 >= line.length || line[index] != '.' || !line[index + 1].isWhitespace()) {
        return null
    }

    val bullet = line.substring(startIndex, index) + "."
    val content = line.substring(index + 2).trimStart()
    return bullet to content
}

private fun parseHeadingLine(line: String, startIndex: Int): MarkdownBlock.Heading? {
    if (startIndex < 0) return null

    val trimmed = line.substring(startIndex)
    // Match from longest to shortest, so `#####` is not truncated to `####`
    return when {
        trimmed.startsWith("###### ") -> MarkdownBlock.Heading(trimmed.removePrefix("###### "), 6)
        trimmed.startsWith("##### ") -> MarkdownBlock.Heading(trimmed.removePrefix("##### "), 5)
        trimmed.startsWith("#### ") -> MarkdownBlock.Heading(trimmed.removePrefix("#### "), 4)
        trimmed.startsWith("### ") -> MarkdownBlock.Heading(trimmed.removePrefix("### "), 3)
        trimmed.startsWith("## ") -> MarkdownBlock.Heading(trimmed.removePrefix("## "), 2)
        trimmed.startsWith("# ") -> MarkdownBlock.Heading(trimmed.removePrefix("# "), 1)
        else -> null
    }
}

internal fun parseBlocks(text: String): List<MarkdownBlock> =
    parseBlocksWithGaps(text).map { it.block }

internal fun parseBlocksWithGaps(text: String): List<MarkdownBlockEntry> {
    if (text.isBlank()) return emptyList()

    val entries = mutableListOf<MarkdownBlockEntry>()
    val lines = text.lines()
    var i = 0
    var pendingBlankLines = 0

    fun emit(block: MarkdownBlock) {
        entries.add(MarkdownBlockEntry(block, pendingBlankLines))
        pendingBlankLines = 0
    }

    while (i < lines.size) {
        val line = lines[i]
        val startIndex = firstNonWhitespaceIndex(line)
        val endExclusive = lastNonWhitespaceExclusive(line)
        val unorderedListContent = parseUnorderedListContent(line, startIndex)
        val orderedListItem = parseOrderedListItem(line, startIndex)
        val heading = parseHeadingLine(line, startIndex)

        when {
            // Code block fence
            startsWithCodeFence(line, startIndex) -> {
                val language = line.substring(startIndex + 3).trim()
                val codeLines = mutableListOf<String>()
                i++
                while (i < lines.size && !startsWithCodeFence(lines[i], firstNonWhitespaceIndex(lines[i]))) {
                    codeLines.add(lines[i])
                    i++
                }
                if (i < lines.size) {
                    i++ // skip closing fence
                } else if (text.endsWith("\n") && codeLines.isNotEmpty() && codeLines.last().isEmpty()) {
                    // Unclosed fence (streaming intermediate state): when text ends with \n, the trailing empty element from lines() is a phantom line
                    // rather than code content — keeping it would make the code lose a trailing blank line when the fence closes, shrinking the card by one line,
                    // which violates render prefix monotonicity (block-commit red line §11)
                    codeLines.removeAt(codeLines.size - 1)
                }
                emit(MarkdownBlock.CodeBlock(codeLines.joinToString("\n"), language))
            }

            // Heading
            heading != null -> {
                emit(heading)
                i++
            }

            // Horizontal rule
            isHorizontalRule(line, startIndex, endExclusive) -> {
                emit(MarkdownBlock.HorizontalRule)
                i++
            }

            // Table (detect pipe at start)
            //
            // GFM semantics tightened: a table forms only when the first "header+separator" pair is found within a run of consecutive pipe lines;
            // pipe lines before it, and runs with no separator at all, are emitted literally as Paragraph —
            // consistent with splitTrailingTable / the streaming table card's decision; otherwise the same text renders as a table while streaming,
            // then as literal after settling (or vice versa) = a sudden switch. The old implementation also silently swallowed a single pipe line
            // (nothing was emitted when size>=2 was not met); this is corrected to Paragraph as well.
            isTableLine(line, startIndex) -> {
                val tableLines = mutableListOf<String>()
                while (i < lines.size && isTableLine(lines[i], firstNonWhitespaceIndex(lines[i]))) {
                    tableLines.add(lines[i])
                    i++
                }
                var sepIdx = -1
                for (k in 1 until tableLines.size) {
                    if (StreamingSplitter.isSeparatorRow(tableLines[k])) {
                        sepIdx = k
                        break
                    }
                }
                if (sepIdx >= 1) {
                    if (sepIdx > 1) {
                        emit(MarkdownBlock.Paragraph(tableLines.subList(0, sepIdx - 1).joinToString("\n")))
                    }
                    val headers = tableLines[sepIdx - 1].split("|").filter { it.isNotBlank() }
                    val rows = tableLines.drop(sepIdx + 1).map { row ->
                        row.split("|").filter { it.isNotBlank() }
                    }
                    emit(MarkdownBlock.Table(headers, rows))
                } else {
                    emit(MarkdownBlock.Paragraph(tableLines.joinToString("\n")))
                }
            }

            // Block math fence — paragraphs starting with $$ are recognized as block math blocks
            //
            // Three valid forms:
            //   1. `$$...$$` single line — $$ at line start and end, with at least 1 non-$ character in between
            //   2. Multi-line block — `$$` alone on a line, followed by content lines until the next `$$` line
            //   3. Tolerant form — starts with `$$x` but the current line does not close, so following lines up to `$$` are included
            //
            // Cases not recognized as block-level (keep original paragraph parsing):
            //   - `$$` immediately followed by letters without closing (half-formed formula, protected by the streaming tail)
            //   - Not at line start (e.g. `prefix $$x$$`, an inline case handled by inline parsing)
            startsWithBlockMathFence(line, startIndex) -> {
                val rest = line.substring(startIndex + 2)
                val trimmedRest = rest.trimEnd()
                // Single-line `$$x$$` form
                if (trimmedRest.length >= 2 && trimmedRest.endsWith("$$")) {
                    val latex = trimmedRest.substring(0, trimmedRest.length - 2).trim()
                    if (latex.isNotEmpty()) {
                        emit(MarkdownBlock.MathBlock(latex))
                        i++
                        continue
                    }
                }

                // Multi-line form: starts with `$$` (possibly followed by content), scans down to the closing `$$` line
                val latexLines = mutableListOf<String>()
                // If the opening line has content (e.g. `$$ x +`), include that first-line content first
                val firstLineContent = rest.trim()
                if (firstLineContent.isNotEmpty()) {
                    latexLines.add(firstLineContent)
                }
                i++
                var closed = false
                while (i < lines.size) {
                    val mathLine = lines[i]
                    val mathStart = firstNonWhitespaceIndex(mathLine)
                    val trimmed = mathLine.trim()
                    // Closing forms: a whole line `$$` or `$$` at line end
                    if (mathStart >= 0 && trimmed == "$$") {
                        closed = true
                        i++
                        break
                    }
                    if (trimmed.endsWith("$$") && trimmed.length >= 2) {
                        val inner = trimmed.substring(0, trimmed.length - 2).trimEnd()
                        if (inner.isNotEmpty()) latexLines.add(inner)
                        closed = true
                        i++
                        break
                    }
                    latexLines.add(mathLine)
                    i++
                }

                if (closed && latexLines.isNotEmpty()) {
                    emit(MarkdownBlock.MathBlock(latexLines.joinToString("\n").trim()))
                } else {
                // Unclosed: fall back to a paragraph keeping the original text, to avoid swallowing following content
                    val raw = buildString {
                        append("$$")
                        if (rest.isNotEmpty()) append(rest)
                        latexLines.drop(if (firstLineContent.isNotEmpty()) 1 else 0).forEach { extra ->
                            append('\n').append(extra)
                        }
                    }
                    emit(MarkdownBlock.Paragraph(raw))
                }
            }

            // Block quote
            isBlockQuoteLine(line) -> {
                val quoteLines = mutableListOf<String>()
                while (i < lines.size && isBlockQuoteLine(lines[i])) {
                    quoteLines.add(lines[i].removePrefix("> "))
                    i++
                }
                emit(MarkdownBlock.BlockQuote(quoteLines.joinToString("\n")))
            }

            // Unordered list
            unorderedListContent != null -> {
                val bullet = "•"
                emit(MarkdownBlock.ListItem(unorderedListContent, bullet))
                i++
            }

            // Ordered list
            orderedListItem != null -> {
                val (bullet, content) = orderedListItem
                emit(MarkdownBlock.ListItem(content, bullet))
                i++
            }

            // Empty line
            startIndex < 0 -> {
                pendingBlankLines++
                i++
            }

            // Paragraph (collect consecutive non-empty lines)
            else -> {
                val paraLines = mutableListOf<String>()
                while (i < lines.size) {
                    val paragraphLine = lines[i]
                    val paragraphStart = firstNonWhitespaceIndex(paragraphLine)
                    val paragraphEnd = lastNonWhitespaceExclusive(paragraphLine)

                    if (
                        paragraphStart < 0 ||
                        startsWithCodeFence(paragraphLine, paragraphStart) ||
                        startsWithBlockMathFence(paragraphLine, paragraphStart) ||
                        parseHeadingLine(paragraphLine, paragraphStart) != null ||
                        isBlockQuoteLine(paragraphLine) ||
                        isTableLine(paragraphLine, paragraphStart) ||
                        isHorizontalRule(paragraphLine, paragraphStart, paragraphEnd) ||
                        canInterruptParagraphAsList(paragraphLine, paragraphStart)
                    ) {
                        break
                    }

                    paraLines.add(lines[i])
                    i++
                }
                if (paraLines.isNotEmpty()) {
                    emit(MarkdownBlock.Paragraph(paraLines.joinToString("\n")))
                }
            }
        }
    }

    return entries
}
