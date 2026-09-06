package ai.oriveo.community.ui.component.markdown

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import ru.noties.jlatexmath.JLatexMathDrawable

/**
 * LaTeX rendering: turns formula source into a bitmap Compose can draw.
 *
 * Backed by ru.noties:jlatexmath-android, which is GPL with the Classpath/linking
 * exception. Its `JLatexMathInitProvider` ContentProvider initialises the library at
 * process start, so nothing has to be called by hand.
 *
 * Rendering is expensive - parsing, a subset of AWT, then a Canvas pass - so every call
 * runs on [Dispatchers.Default], and an [LruCache] keeps the most recent bitmaps so the
 * same formula is never rendered twice.
 */
internal object LatexBitmapCache {

    /** Cache key: the full LaTeX source plus the parameters it was rendered with. */
    private data class Key(
        val latex: String,
        val textSizePx: Int,
        val colorArgb: Int,
    )

    // 4MB budget, charged by Bitmap.byteCount; 1MB is roughly a 1024x256 RGBA bitmap.
    // Scrolling back through a conversation reuses entries heavily, and 4MB holds
    // somewhere around 50 to 100 medium-sized formulas.
    private const val MAX_CACHE_BYTES = 4 * 1024 * 1024
    const val MAX_BITMAP_PIXELS = MAX_CACHE_BYTES / 4
    const val MAX_BITMAP_DIMENSION = 4_096

    private val cache = object : LruCache<Key, Bitmap>(MAX_CACHE_BYTES) {
        override fun sizeOf(key: Key, value: Bitmap): Int = value.byteCount
    }

    private val cacheLock = Any()

    fun get(latex: String, textSizePx: Int, colorArgb: Int): Bitmap? =
        synchronized(cacheLock) { cache.get(Key(latex, textSizePx, colorArgb)) }

    fun put(latex: String, textSizePx: Int, colorArgb: Int, bitmap: Bitmap) {
        synchronized(cacheLock) {
            cache.put(Key(latex, textSizePx, colorArgb), bitmap)
        }
    }
}

/**
 * Renders a LaTeX string into a bitmap.
 *
 * @param latex the formula source, without its `$...$` or `$$...$$` delimiters.
 * @param textSizePx the target base size for the maths symbols in pixels, normally the
 *   font size multiplied by the display density.
 * @param colorArgb the colour to draw the formula in, as a packed ARGB int.
 * @return the rendered bitmap, or null for a blank source, for a formula the library
 *   cannot parse, or for one whose bitmap would exceed the size budget.
 */
internal fun renderLatexBitmap(
    latex: String,
    textSizePx: Int,
    colorArgb: Int,
): Bitmap? {
    if (latex.isBlank()) return null
    LatexBitmapCache.get(latex, textSizePx, colorArgb)?.let { return it }

    return try {
        val drawable: JLatexMathDrawable = JLatexMathDrawable.builder(latex)
            .textSize(textSizePx.toFloat())
            .color(colorArgb)
            .padding(0)
            .align(JLatexMathDrawable.ALIGN_LEFT)
            .build()
        val width = drawable.intrinsicWidth.coerceAtLeast(1)
        val height = drawable.intrinsicHeight.coerceAtLeast(1)
        if (!isLatexBitmapWithinBudget(width, height)) return null
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, width, height)
        drawable.draw(Canvas(bitmap))
        LatexBitmapCache.put(latex, textSizePx, colorArgb, bitmap)
        bitmap
    } catch (t: Throwable) {
        // The library throws ParseException subclasses on an invalid formula. One bad
        // formula must not take the rest of the message down with it.
        null
    }
}

internal fun isLatexBitmapWithinBudget(width: Int, height: Int): Boolean =
    width > 0 &&
        height > 0 &&
        width <= LatexBitmapCache.MAX_BITMAP_DIMENSION &&
        height <= LatexBitmapCache.MAX_BITMAP_DIMENSION &&
        width.toLong() * height.toLong() <= LatexBitmapCache.MAX_BITMAP_PIXELS

/** Placeholder key for a block formula's inlineContent; a MathBlockView only ever has one. */
private const val BLOCK_MATH_INLINE_KEY = "oriveo.blockMath"

/**
 * A block formula, i.e. a `$$...$$` paragraph.
 *
 * The bitmap is rendered asynchronously. Until it is ready the raw LaTeX is shown with
 * its `$$` delimiters, which reads sensibly on its own and makes the transition during
 * streaming unobtrusive; if rendering fails it stays that way. The content scrolls
 * horizontally so that an over-wide formula cannot burst the message bubble.
 */
@Composable
internal fun MathBlockView(
    latex: String,
    mdColors: MarkdownColors,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val baseFontSize: TextUnit = OriveoTheme.typography.chatBody.fontSize.takeIf { it != TextUnit.Unspecified } ?: 16.sp
    val textSizePx = remember(baseFontSize, density) {
        with(density) {
            // Block formulas are set slightly larger than body text, which matches the
            // visual weight they carry in other editors.
            (baseFontSize.toPx() * 1.2f).toInt().coerceAtLeast(12)
        }
    }
    val colorArgb = mdColors.text.toArgb()

    // Try the cache synchronously first: a formula already rendered at these parameters
    // appears immediately instead of flickering through the loading state.
    var bitmap by remember(latex, textSizePx, colorArgb) {
        mutableStateOf(LatexBitmapCache.get(latex, textSizePx, colorArgb))
    }
    var failed by remember(latex, textSizePx, colorArgb) {
        mutableStateOf(false)
    }

    LaunchedEffect(latex, textSizePx, colorArgb) {
        if (bitmap != null || failed) return@LaunchedEffect
        val rendered = withContext(Dispatchers.Default) {
            renderLatexBitmap(latex, textSizePx, colorArgb)
        }
        if (rendered != null) bitmap = rendered else failed = true
    }

    val displayBitmap = bitmap
    Box(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        contentAlignment = Alignment.CenterStart,
    ) {
        when {
            displayBitmap != null -> {
                val heightDp: Dp = with(density) { displayBitmap.height.toDp() }
                // Contributing the source to the selection: an Image does not take part in
                // Compose's selectable text flow. Rendering the formula as a Text holding a
                // single inlineContent placeholder sized to the bitmap makes it a
                // first-class member of the SelectionContainer - long-press starts a
                // selection on it and the highlight covers the whole formula - while copy
                // and save-as-note pick up the `$$..$$` source from the alternate text.
                // The earlier approach overlaid the source as 1.sp transparent text, which
                // was invisible and almost impossible to hit, so formulas simply could not
                // be selected. Only the bitmap branch needs this; the loading and failure
                // branches already display the source as ordinary Text.
                Text(
                    text = buildAnnotatedString {
                        appendInlineContent(BLOCK_MATH_INLINE_KEY, "\$\$$latex\$\$")
                    },
                    inlineContent = mapOf(
                        BLOCK_MATH_INLINE_KEY to InlineTextContent(
                            Placeholder(
                                width = with(density) { displayBitmap.width.toFloat().toSp() },
                                height = with(density) { displayBitmap.height.toFloat().toSp() },
                                placeholderVerticalAlign = PlaceholderVerticalAlign.Center,
                            ),
                        ) {
                            Image(
                                bitmap = displayBitmap.asImageBitmap(),
                                contentDescription = null,
                                modifier = Modifier.height(heightDp),
                                // Image defaults to Fit, which keeps the original pixel
                                // dimensions rather than stretching the formula.
                            )
                        },
                    ),
                    modifier = Modifier.padding(vertical = 2.dp),
                    maxLines = 1,
                    softWrap = false,
                )
            }

            failed -> {
                // Parsing failed: fall back to the source so the user can still read,
                // copy and correct it.
                Text(
                    text = "\$\$$latex\$\$",
                    style = OriveoTheme.typography.chatBody.copy(color = mdColors.text),
                )
            }

            else -> {
                // Still loading: show the source rather than an empty gap.
                Text(
                    text = "\$\$$latex\$\$",
                    style = OriveoTheme.typography.chatBody.copy(color = mdColors.textSecondary),
                    textAlign = TextAlign.Start,
                )
            }
        }
    }
}

/**
 * Renders an inline formula to a comparatively small bitmap, sized to sit on the text
 * baseline.
 *
 * @param latex the formula source, without its `$...$` delimiters.
 * @param colors the Markdown palette; the formula is drawn in its text colour.
 * @param fontSize the surrounding text size the formula should match.
 * @return the bitmap once it is ready, or null while it is still rendering.
 */
@Composable
internal fun InlineMathBitmap(
    latex: String,
    colors: MarkdownColors,
    fontSize: TextUnit,
): Bitmap? {
    val density = LocalDensity.current
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
    return bitmap
}

/**
 * Whether the text ends inside an unclosed formula.
 *
 * A streaming tail with an open formula is displayed as plain text instead of being
 * rendered, which stops a half-written formula from jittering as it is typeset.
 */
fun hasOpenMathDelimiter(text: String): Boolean {
    val r = splitClosedAndOpenLatex(text)
    return r.tail.isNotEmpty()
}
