package ai.oriveo.community.ui.component.markdown

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Inline maths support: while rendering a paragraph, `$...$` runs are recognised and the
 * text is split into plain runs and formula runs.
 *
 * The strategy is:
 * 1. [extractInlineMath] scans the text for every `$...$` that stays on one line and is
 *    not inside inline code;
 * 2. at render time each formula run becomes an `appendInlineContent` placeholder;
 * 3. [buildInlineMathContent] binds those placeholders to asynchronously rendered bitmaps.
 *
 * Paragraphs and table cells go through this module. Headings, list items and quotes do
 * not support inline maths: they are rarer, and lists and quotes still use the fade
 * overlay, whose alpha span has no effect on an [InlineTextContent].
 */

internal data class InlineMathSpan(
    val start: Int,
    val endExclusive: Int,
    val latex: String,
)

/** Key prefix for entries in an AnnotatedString's inlineContent map. */
private const val INLINE_MATH_KEY_PREFIX = "oriveo.inlineMath."

internal fun inlineMathKey(idx: Int): String = "$INLINE_MATH_KEY_PREFIX$idx"

/**
 * Finds inline `$...$` formulas in paragraph text.
 *
 * The rules are deliberately conservative, so that ordinary markdown and currency
 * amounts are not mistaken for maths:
 *   - the opening `$` may not be preceded by a `\` (an escape) or by an alphanumeric
 *     character, which keeps `bar$x` out;
 *   - the opening `$` must be followed immediately by something other than a space, a
 *     `$`, a digit or a newline;
 *   - the content may not span lines - a `\n` abandons the candidate;
 *   - the closing `$` may not be preceded by a space, which rejects half-written runs
 *     such as "$x + y $";
 *   - the closing `$` may not be followed by a digit, which keeps "$5" and "$10" as
 *     currency;
 *   - nothing inside inline code is considered at all.
 *
 * @param text the paragraph source.
 * @return the formula spans in the order they appear.
 */
internal fun extractInlineMath(text: String): List<InlineMathSpan> {
    if (text.isEmpty() || !text.contains('$')) return emptyList()

    val result = mutableListOf<InlineMathSpan>()
    var i = 0
    val len = text.length
    var inInlineCode = false
    var codeFenceLen = 0

    while (i < len) {
        val ch = text[i]

        // Inline code, either `...` or ``...``.
        if (ch == '`') {
            if (inInlineCode) {
                // Look for the closing run.
                var j = i
                while (j < len && text[j] == '`') j++
                if (j - i == codeFenceLen) {
                    inInlineCode = false
                    codeFenceLen = 0
                    i = j
                    continue
                }
                i = j
                continue
            } else {
                var j = i
                while (j < len && text[j] == '`') j++
                inInlineCode = true
                codeFenceLen = j - i
                i = j
                continue
            }
        }

        if (inInlineCode) {
            // Inline code never spans lines, so a newline closes it implicitly.
            if (ch == '\n') {
                inInlineCode = false
                codeFenceLen = 0
            }
            i++
            continue
        }

        if (ch == '$' && (i == 0 || text[i - 1] != '\\') && (i + 1 >= len || text[i + 1] != '$')) {
            // Check whether this $ is eligible to open a formula.
            val prev = if (i > 0) text[i - 1] else null
            if (prev != null && (prev.isLetterOrDigit())) {
                i++
                continue
            }
            val next = if (i + 1 < len) text[i + 1] else null
            if (next == null || next == ' ' || next == '\t' || next == '\n' || next == '$' || next.isDigit()) {
                i++
                continue
            }

            // Look for a closing $.
            var j = i + 1
            var closed = -1
            while (j < len) {
                val cj = text[j]
                if (cj == '\n') break
                if (cj == '\\' && j + 1 < len && text[j + 1] == '$') {
                    j += 2
                    continue
                }
                if (cj == '$') {
                    // Closing eligibility: the previous character must not be a space and
                    // the next must not be a digit.
                    val prevCh = text[j - 1]
                    val nextCh = if (j + 1 < len) text[j + 1] else null
                    val notDoubleDollar = nextCh != '$'
                    if (prevCh != ' ' && prevCh != '\t' && (nextCh == null || !nextCh.isDigit()) && notDoubleDollar) {
                        closed = j
                        break
                    }
                }
                j++
            }

            if (closed > i + 1) {
                val latex = text.substring(i + 1, closed)
                if (latex.isNotBlank()) {
                    result.add(InlineMathSpan(start = i, endExclusive = closed + 1, latex = latex))
                    i = closed + 1
                    continue
                }
            }
        }

        i++
    }

    return result
}

internal data class InlineMarkdownWithMath(
    val annotated: AnnotatedString,
    val mathSpans: List<InlineMathSpan>,
)

/**
 * Splits paragraph text into plain runs and formula runs and builds the mixed
 * [AnnotatedString].
 *
 * Plain runs go through [MarkdownRenderer], so bold, italic and links survive. Formula
 * runs become an `appendInlineContent(key, "$latex$")` placeholder that the caller fills
 * with the rendered bitmap through its inlineContent map.
 *
 * The alternate text deliberately keeps the `$` delimiters, because that is the text a
 * user gets when they copy the selection or save a highlighted passage as a note. Bare
 * LaTeX would lose its delimiters and could never be rendered as a formula again.
 *
 * @param text the paragraph source.
 * @param colors the palette for the plain runs.
 * @return the rendered string together with the formula spans, which carry the LaTeX the
 *   inlineContent map has to render.
 */
internal fun renderInlineMarkdownWithMath(
    text: String,
    colors: MarkdownColors,
): InlineMarkdownWithMath {
    val spans = extractInlineMath(text)
    if (spans.isEmpty()) {
        return InlineMarkdownWithMath(
            annotated = MarkdownRenderer.render(text, colors),
            mathSpans = emptyList(),
        )
    }

    val annotated = buildAnnotatedString {
        var cursor = 0
        spans.forEachIndexed { idx, span ->
            if (span.start > cursor) {
                val chunk = text.substring(cursor, span.start)
                append(MarkdownRenderer.render(chunk, colors))
            }
            appendInlineContent(inlineMathKey(idx), "\$${span.latex}\$")
            cursor = span.endExclusive
        }
        if (cursor < text.length) {
            val tail = text.substring(cursor)
            append(MarkdownRenderer.render(tail, colors))
        }
    }

    return InlineMarkdownWithMath(annotated = annotated, mathSpans = spans)
}

/**
 * Renders one inline maths placeholder.
 *
 * A cache hit shows the bitmap immediately; a miss starts an asynchronous render and
 * shows the raw `$latex$` in the meantime, so the line never collapses to nothing.
 */
@Composable
internal fun InlineMathPlaceholder(
    latex: String,
    style: TextStyle,
    colors: MarkdownColors,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val fontSize = style.fontSize.takeIf { it.isSp } ?: 16.sp
    val textSizePx = remember(fontSize, density) {
        with(density) { fontSize.toPx().toInt().coerceAtLeast(10) }
    }
    val colorArgb = colors.text.toArgb()

    var bitmap by remember(latex, textSizePx, colorArgb) {
        mutableStateOf(LatexBitmapCache.get(latex, textSizePx, colorArgb))
    }
    LaunchedEffect(latex, textSizePx, colorArgb) {
        if (bitmap != null) return@LaunchedEffect
        bitmap = withContext(Dispatchers.Default) {
            renderLatexBitmap(latex, textSizePx, colorArgb)
        }
    }

    val displayBitmap = bitmap
    Box(
        modifier = modifier,
        contentAlignment = Alignment.CenterStart,
    ) {
        if (displayBitmap != null) {
            val w: Dp = with(density) { displayBitmap.width.toDp() }
            val h: Dp = with(density) { displayBitmap.height.toDp() }
            Image(
                bitmap = displayBitmap.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier.size(width = w, height = h),
            )
        } else {
            Text(
                text = "\$$latex\$",
                style = style.copy(textDecoration = TextDecoration.None),
            )
        }
    }
}

/**
 * Computes the inline [Placeholder] size for a formula at a given font size.
 *
 * A cache hit gives the exact size straight away. On a miss it returns a conservative
 * estimate derived from the character count and the font size; the asynchronous render
 * then triggers a recomposition with the real dimensions.
 */
@Composable
internal fun rememberInlineMathPlaceholder(
    latex: String,
    style: TextStyle,
    colors: MarkdownColors,
): Placeholder {
    val density = LocalDensity.current
    val fontSize = style.fontSize.takeIf { it.isSp } ?: 16.sp
    val textSizePx = remember(fontSize, density) {
        with(density) { fontSize.toPx().toInt().coerceAtLeast(10) }
    }
    val colorArgb = colors.text.toArgb()
    val cached: Bitmap? = LatexBitmapCache.get(latex, textSizePx, colorArgb)
    val baseLine = fontSize
    val widthSp = if (cached != null) {
        with(density) { cached.width.toDp().value.coerceAtLeast(8f).sp }
    } else {
        // Width estimate: character count times a fraction of the font size.
        (latex.length.coerceAtLeast(1) * 0.65f * baseLine.value).coerceAtLeast(8f).sp
    }
    val heightSp = if (cached != null) {
        with(density) { cached.height.toDp().value.coerceAtLeast(8f).sp }
    } else {
        (baseLine.value * 1.3f).coerceAtLeast(8f).sp
    }
    return Placeholder(
        width = widthSp,
        height = heightSp,
        placeholderVerticalAlign = PlaceholderVerticalAlign.Center,
    )
}

/** Turns the formula spans from [renderInlineMarkdownWithMath] into a Compose inlineContent map. */
@Composable
internal fun buildInlineMathContent(
    spans: List<InlineMathSpan>,
    style: TextStyle,
    colors: MarkdownColors,
): Map<String, InlineTextContent> {
    if (spans.isEmpty()) return emptyMap()
    val map = mutableMapOf<String, InlineTextContent>()
    spans.forEachIndexed { idx, span ->
        val placeholder = rememberInlineMathPlaceholder(span.latex, style, colors)
        map[inlineMathKey(idx)] = InlineTextContent(placeholder) {
            InlineMathPlaceholder(
                latex = span.latex,
                style = style,
                colors = colors,
            )
        }
    }
    return map
}
