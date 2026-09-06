package ai.oriveo.community.ui.component.markdown

import android.widget.Toast
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
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.component.coerceHeightConstraintPx
import ai.oriveo.community.R
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.streaming.StreamingRevealState
import ai.oriveo.community.ui.component.streaming.rememberStreamingReveal
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlin.math.roundToInt

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

val LocalMarkdownTextScale = staticCompositionLocalOf { 1f }

@Composable
private fun markdownBodyStyle(): TextStyle {
    val scale = LocalMarkdownTextScale.current
    val base = OriveoTheme.typography.chatBody
    return if (scale == 1f) {
        base
    } else {
        base.copy(fontSize = base.fontSize * scale, lineHeight = base.lineHeight * scale)
    }
}

@Composable
private fun markdownCaptionStyle(): TextStyle {
    val scale = LocalMarkdownTextScale.current
    val base = OriveoTheme.typography.caption
    return if (scale == 1f) {
        base
    } else {
        base.copy(fontSize = base.fontSize * scale, lineHeight = base.lineHeight * scale)
    }
}

@Composable
fun MarkdownMessageView(
    text: String,
    modifier: Modifier = Modifier,
    isStreaming: Boolean = false,
    isUserMessage: Boolean = false,

    onRenderSettled: (() -> Unit)? = null,

    onRenderStreamingChanged: ((Boolean) -> Unit)? = null,

    onSaveCodeBlock: ((String) -> Unit)? = null,

    onSaveSelection: ((String) -> Unit)? = null,
    /** Settled chat messages expose Ask using the copied rendered selection. */
    onAskSelection: ((QuoteSelectionContent) -> Unit)? = null,

    onReplaceSelection: ((String) -> Unit)? = null,

    onSelectionToolbarVisibleChange: (Boolean) -> Unit = {},

    onSelectionGestureActiveChange: (Boolean) -> Unit = {},

    selectable: Boolean = true,

    emphasizedHeadings: Boolean = false,
) {
    val mdColors = MarkdownTheme.colors()

    val reveal = rememberStreamingReveal(target = text, isStreaming = isStreaming)

    var everStreamed by remember { mutableStateOf(false) }
    LaunchedEffect(isStreaming) { if (isStreaming) everStreamed = true }
    val renderStreaming = isStreaming ||
        (everStreamed && (reveal.visibleText.length < text.length || reveal.isFading))

    var wasRenderStreaming by remember { mutableStateOf(false) }
    LaunchedEffect(renderStreaming) {
        onRenderStreamingChanged?.invoke(renderStreaming)
        if (wasRenderStreaming && !renderStreaming) onRenderSettled?.invoke()
        wasRenderStreaming = renderStreaming
    }

    val flooredModifier = modifier.streamingHeightFloor(active = renderStreaming)

    val settled = !renderStreaming

    val sourceText = if (settled) text else reveal.visibleText
    val normalized = remember(sourceText, settled) {
        if (settled) {
            normalizeLatexDelimiters(sourceText) to ""
        } else {
            val split = splitClosedAndOpenLatex(sourceText)
            normalizeLatexDelimiters(split.closed) to split.tail
        }
    }

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

@Composable
private fun Modifier.streamingHeightFloor(active: Boolean): Modifier {
    val density = LocalDensity.current
    var floorPx by remember { mutableIntStateOf(0) }
    var clampActive by remember { mutableStateOf(false) }
    LaunchedEffect(active) {
        if (active) {
            clampActive = true
        } else {

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

    val split = remember(text, settled) {
        if (settled) {
            StreamingSplitter.SplitResult(committed = text, tail = "")
        } else {

            val gate = (text.length - reveal.unsettledTailApprox).coerceAtLeast(0)
            StreamingSplitter.split(text, maxEnd = gate)
        }
    }

    Column(modifier = modifier) {

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

        if (split.tail.isNotEmpty()) {

            val trailingTable = remember(split.tail) { StreamingSplitter.splitTrailingTable(split.tail) }

            if (split.committed.isNotEmpty()) {
                val seamGap = remember(split.committed, split.tailKind, trailingTable != null) {
                    streamingSeamSpacing(split.committed, split.tail, split.tailKind, trailingTable != null)
                }
                Spacer(modifier = Modifier.height(seamGap))
            }
            if (trailingTable != null) {
                if (trailingTable.beforeTable.isNotBlank()) {

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

                        Text(
                            text = split.tail,
                            style = markdownBodyStyle().copy(color = mdColors.text),
                        )
                    }
                    StreamingSplitter.TailKind.Paragraph -> {

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

        if (tailText.isNotEmpty()) {
            Text(
                text = tailText,
                style = markdownBodyStyle().copy(color = mdColors.text),
            )
        }
    }
}

@Composable
private fun FadableAnnotatedText(
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

    reveal.frameNanos
    val ledger = remember { FadeAlphaLedger() }
    val faded = applyTailFade(rendered, baseColor, reveal, distFromRenderedEnd, ledger)
    DisableSelection {
        ClickableAnnotatedText(faded, style, modifier)
    }
}

internal class FadeAlphaLedger {
    private var maxAlpha = IntArray(0)
    private var length = 0

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

internal fun composeFadedSpans(
    src: AnnotatedString,
    baseColor: Color,
    alphas: IntArray,
    firstUnsettled: Int,
): AnnotatedString {
    val n = src.length

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
) {
    val entries = rememberMarkdownBlockEntries(text)

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

                        val headingScale = LocalMarkdownTextScale.current
                        val headingSize =
                            if (headingScale == 1f) headingBaseSize else headingBaseSize * headingScale

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
                            )
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

private fun blockSourceLengthApprox(block: MarkdownBlock): Int = when (block) {
    is MarkdownBlock.Paragraph -> block.text.length
    is MarkdownBlock.Heading -> block.text.length
    is MarkdownBlock.BlockQuote -> block.text.length
    is MarkdownBlock.ListItem -> block.text.length
    else -> 0
}

@Composable
private fun ParagraphWithInlineMath(
    text: String,
    mdColors: MarkdownColors,
) {
    val style = markdownBodyStyle().copy(color = mdColors.text)
    val context = LocalContext.current
    val withMath = remember(text, mdColors) { renderInlineMarkdownWithMath(text, mdColors) }
    val annotated = remember(withMath, context) { withMath.annotated.withSafeLinkHandling(context) }
    val inlineContent = buildInlineMathContent(
        spans = withMath.mathSpans,
        style = style,
        colors = mdColors,
    )
    Text(
        text = annotated,
        style = style,
        inlineContent = inlineContent,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun ClickableAnnotatedText(
    text: AnnotatedString,
    style: androidx.compose.ui.text.TextStyle,
    modifier: Modifier = Modifier,
) {

    val context = LocalContext.current
    val safeText = remember(text, context) { text.withSafeLinkHandling(context) }
    Text(
        text = safeText,
        style = style,
        modifier = modifier,
    )
}

private fun AnnotatedString.withSafeLinkHandling(
    context: android.content.Context,
): AnnotatedString {
    if (getLinkAnnotations(0, length).isEmpty()) return this
    return mapAnnotations { range ->
        val link = range.item as? LinkAnnotation.Url ?: return@mapAnnotations range
        val safe = LinkAnnotation.Url(link.url, link.styles) {
            val url = (it as LinkAnnotation.Url).url
            if (!openExternalUrl(context, url)) {
                Toast.makeText(context, R.string.link_open_failed_message, Toast.LENGTH_LONG).show()
            }
        }
        @Suppress("UNCHECKED_CAST")
        (range as AnnotatedString.Range<AnnotatedString.Annotation>).copy(item = safe)
    }
}

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

    val withMath = remember(normalized, mdColors) { renderInlineMarkdownWithMath(normalized, mdColors) }
    val annotated = remember(withMath, context) { withMath.annotated.withSafeLinkHandling(context) }
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

    data class MathBlock(val latex: String) : MarkdownBlock()
}

internal data class MarkdownBlockEntry(
    val block: MarkdownBlock,
    val gapBefore: Int,
)

// ── Block-pair spacing (rendering) ──

internal fun spacerHeightBetween(
    prev: MarkdownBlock,
    curr: MarkdownBlock,
    blankLinesBetween: Int,
    emphasized: Boolean = false,
): Dp {
    val hasBlank = blankLinesBetween > 0
    return when {

        curr is MarkdownBlock.Heading -> if (emphasized) 28.dp else 20.dp

        prev is MarkdownBlock.Heading -> 6.dp

        prev is MarkdownBlock.ListItem && curr is MarkdownBlock.ListItem ->
            if (hasBlank) 10.dp else 4.dp

        prev is MarkdownBlock.CodeBlock || curr is MarkdownBlock.CodeBlock -> 12.dp
        prev is MarkdownBlock.Table || curr is MarkdownBlock.Table -> 12.dp
        prev is MarkdownBlock.BlockQuote || curr is MarkdownBlock.BlockQuote -> 12.dp
        prev is MarkdownBlock.HorizontalRule || curr is MarkdownBlock.HorizontalRule -> 12.dp
        prev is MarkdownBlock.MathBlock || curr is MarkdownBlock.MathBlock -> 12.dp

        else -> if (hasBlank) (if (emphasized) 18.dp else 16.dp) else 8.dp
    }
}

internal fun streamingSeamSpacing(
    committed: String,
    tail: String,
    tailKind: StreamingSplitter.TailKind,
    tailIsTable: Boolean,
): Dp {

    val prev = MarkdownRenderCache.blockEntries(committed).lastOrNull()?.block ?: return 0.dp
    val curr: MarkdownBlock = when {
        tailIsTable -> MarkdownBlock.Table(emptyList(), emptyList())
        tailKind == StreamingSplitter.TailKind.UnclosedCodeFence -> MarkdownBlock.CodeBlock("", "")
        tailKind == StreamingSplitter.TailKind.UnclosedMathBlock -> MarkdownBlock.MathBlock("")
        else -> parseBlocks(tail).firstOrNull() ?: MarkdownBlock.Paragraph(tail)
    }

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
                is MarkdownBlock.MathBlock -> Unit
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

            startsWithBlockMathFence(line, startIndex) -> {
                val rest = line.substring(startIndex + 2)
                val trimmedRest = rest.trimEnd()

                if (trimmedRest.length >= 2 && trimmedRest.endsWith("$$")) {
                    val latex = trimmedRest.substring(0, trimmedRest.length - 2).trim()
                    if (latex.isNotEmpty()) {
                        emit(MarkdownBlock.MathBlock(latex))
                        i++
                        continue
                    }
                }

                val latexLines = mutableListOf<String>()

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
                        isHorizontalRule(paragraphLine, paragraphStart, paragraphEnd)
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
