package ai.oriveo.community.ui.theme

import android.graphics.BlurMaskFilter
import android.graphics.Paint as AndroidPaint
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.GlobalPositionAwareModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import java.util.concurrent.ConcurrentHashMap

/**
 * User bubble: a viewport-anchored vertical gradient.
 *
 * One vertical gradient (7 OKLCH stops, top -> bottom) spans the chat viewport and every bubble only draws its own segment of it;
 * the outer shadow uses the bottom color @ 0.16, with a 1dp white inner highlight at the top. Contract source:
 * `derived.userBubble` in `shared/theme-contracts/dark-palettes.v1.json`; the stops are a port of the contract's reference `bubbleStops` / `bubbleFor`.
 */
object OriveoUserBubble {

    // JSON `derived.userBubble`
    const val STOP_COUNT = 7
    const val HIGHLIGHT_ALPHA_DARK = 0.22f
    const val HIGHLIGHT_ALPHA_LIGHT = 0.28f
    const val HIGHLIGHT_WIDTH_DP = 1f
    const val SHADOW_ALPHA = 0.16f
    const val SHADOW_BLUR_DP = 14f
    const val SHADOW_Y_DP = 4f

    /** Below this chroma an endpoint's hue is unreliable, so the hue of the other end is borrowed (same as `bubbleStops`). */
    private const val ACHROMATIC_CHROMA = 0.02

    private val cache = ConcurrentHashMap<Pair<DarkPaletteChoice, Boolean>, List<Color>>()

    /**
     * The bubble stops of a palette under an appearance (top -> bottom; cached, called at high frequency during rendering).
     * Dark = accent -> primary; light = the light brand gradEnd -> gradStart (as `bubbleFor`).
     */
    fun stops(choice: DarkPaletteChoice, isDark: Boolean): List<Color> = cache.getOrPut(choice to isDark) {
        val (top, bottom) = if (isDark) {
            choice.colors.let { it.accent to it.primary }
        } else {
            choice.lightBrand.let { it.gradEnd to it.gradStart }
        }
        bubbleStops(top.rgb(), bottom.rgb(), STOP_COUNT).map { Color(0xFF000000.toInt() or it) }
    }

    /** Step by step as `bubbleStops`: the two ends are interpolated linearly in OKLCH (hue along the short arc), returning `0xRRGGBB`. */
    internal fun bubbleStops(top: Int, bottom: Int, count: Int): List<Int> {
        val a = OriveoCustomPalette.oklch(top)
        val b = OriveoCustomPalette.oklch(bottom)
        var ha = a[2]
        var hb = b[2]
        if (a[1] < ACHROMATIC_CHROMA) ha = hb
        if (b[1] < ACHROMATIC_CHROMA) hb = ha
        var dh = hb - ha
        if (dh > 180) dh -= 360
        if (dh < -180) dh += 360
        return List(count) { i ->
            val t = if (count == 1) 0.0 else i.toDouble() / (count - 1)
            OriveoCustomPalette.fromOklch(
                a[0] + (b[0] - a[0]) * t,
                a[1] + (b[1] - a[1]) * t,
                (ha + dh * t + 360) % 360,
            )
        }
    }

    /** Production bubble style: the current palette + appearance. */
    fun style(choice: DarkPaletteChoice, isDark: Boolean): UserBubbleStyle = UserBubbleStyle(stops(choice, isDark), isDark)

    /**
     * Anchoring: with a viewport of height [viewportHeight] and the bubble top at viewport y = [bubbleTop], the start / end y of the gradient in the bubble's own coordinates.
     * The start is -t and the end is H - t, so the bubble shows the [t, t + h] segment of the gradient.
     */
    fun span(viewportHeight: Float, bubbleTop: Float): UserBubbleSpan =
        UserBubbleSpan(startY = -bubbleTop, endY = viewportHeight - bubbleTop)

    private fun Color.rgb(): Int = toArgb() and 0xFFFFFF
}

/** Start / end y (vertical) of the gradient in the bubble's own coordinates. */
@Immutable
data class UserBubbleSpan(val startY: Float, val endY: Float)

/** What one user bubble draws: the vertical stops, the outer shadow color and the top inner highlight alpha. */
@Immutable
data class UserBubbleStyle(val stops: List<Color>, val isDark: Boolean) {
    /** Outer shadow: the bottom color @ 0.16. */
    val shadowColor: Color get() = stops.last().copy(alpha = OriveoUserBubble.SHADOW_ALPHA)

    /** Top inner highlight: white @ 0.22 in dark / 0.28 in light. */
    val highlightColor: Color
        get() = Color.White.copy(
            alpha = if (isDark) OriveoUserBubble.HIGHLIGHT_ALPHA_DARK else OriveoUserBubble.HIGHLIGHT_ALPHA_LIGHT,
        )

    /** Gradient brush: [span] is the start / end y in the bubble's own coordinates. */
    fun brush(span: UserBubbleSpan): Brush = Brush.verticalGradient(stops, startY = span.startY, endY = span.endY)
}

/**
 * The top y and height, in the window, of the container the gradient is anchored to (chat viewport / theme page preview card / palette card).
 * It is only read in the draw phase (the draw of [userBubbleFill]); scrolling / keyboard / rotation only trigger a redraw, not recomposition or layout.
 */
@Stable
class UserBubbleViewport {
    var top: Float by mutableFloatStateOf(0f)
        internal set
    var height: Float by mutableFloatStateOf(0f)
        internal set
}

/** The viewport provided by the chat list; when null the bubble is anchored to itself. */
val LocalUserBubbleViewport = staticCompositionLocalOf<UserBubbleViewport?> { null }

/** Registers the current node as the anchor container of the bubble gradient. */
fun Modifier.userBubbleViewport(viewport: UserBubbleViewport): Modifier = onGloballyPositioned { coordinates ->
    viewport.top = coordinates.positionInWindow().y
    viewport.height = coordinates.size.height.toFloat()
}

/**
 * User bubble background: a vertical gradient anchored to [viewport]; when [decorated], it also draws the outer shadow and the top inner highlight.
 * The bubble position is kept in the node and a change only calls invalidateDraw; the viewport geometry is read as State in draw (likewise only a redraw).
 */
fun Modifier.userBubbleFill(
    style: UserBubbleStyle,
    shape: Shape,
    viewport: UserBubbleViewport?,
    decorated: Boolean = true,
): Modifier = this then UserBubbleFillElement(style, shape, viewport, decorated)

private data class UserBubbleFillElement(
    val style: UserBubbleStyle,
    val shape: Shape,
    val viewport: UserBubbleViewport?,
    val decorated: Boolean,
) : ModifierNodeElement<UserBubbleFillNode>() {
    override fun create() = UserBubbleFillNode(style, shape, viewport, decorated)

    override fun update(node: UserBubbleFillNode) {
        if (node.shape != shape) node.resetGeometry()
        node.style = style
        node.shape = shape
        node.viewport = viewport
        node.decorated = decorated
        node.invalidateDraw()
    }
}

private class UserBubbleFillNode(
    var style: UserBubbleStyle,
    var shape: Shape,
    var viewport: UserBubbleViewport?,
    var decorated: Boolean,
) : Modifier.Node(), DrawModifierNode, GlobalPositionAwareModifierNode {

    private var topInWindow = Float.NaN

    // Geometry cached by size / direction (outline, highlight, shadow paint)
    private var cachedSize = Size.Unspecified
    private var cachedDirection: LayoutDirection? = null
    private var cachedDensity = 0f
    private var outline: Outline? = null
    private var highlightPath: Path? = null
    private var shadowPath: android.graphics.Path? = null
    private var shadowPaint: AndroidPaint? = null

    fun resetGeometry() {
        cachedSize = Size.Unspecified
    }

    override fun onGloballyPositioned(coordinates: LayoutCoordinates) {
        val y = coordinates.positionInWindow().y
        if (y != topInWindow) {
            topInWindow = y
            invalidateDraw()
        }
    }

    override fun ContentDrawScope.draw() {
        if (size != cachedSize || layoutDirection != cachedDirection || density != cachedDensity) {
            cachedSize = size
            cachedDirection = layoutDirection
            cachedDensity = density
            val o = shape.createOutline(size, layoutDirection, this)
            outline = o
            val body = Path().apply { addOutline(o) }
            val shifted = Path().apply {
                addOutline(o)
                translate(Offset(0f, OriveoUserBubble.HIGHLIGHT_WIDTH_DP.dp.toPx()))
            }
            highlightPath = Path().apply { op(body, shifted, PathOperation.Difference) }
            shadowPath = body.asAndroidPath()
            // Blur follows the CSS convention: blur = 2 sigma; BlurMaskFilter takes a radius (Skia: sigma ~= radius * 0.57735 + 0.5)
            val sigma = OriveoUserBubble.SHADOW_BLUR_DP.dp.toPx() / 2f
            shadowPaint = AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
                style = AndroidPaint.Style.FILL
                maskFilter = BlurMaskFilter(((sigma - 0.5f) / 0.57735f).coerceAtLeast(1f), BlurMaskFilter.Blur.NORMAL)
            }
        }
        val current = style
        if (decorated) {
            val paint = shadowPaint
            val path = shadowPath
            if (paint != null && path != null) {
                paint.color = current.shadowColor.toArgb()
                val dy = OriveoUserBubble.SHADOW_Y_DP.dp.toPx()
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.save()
                    canvas.nativeCanvas.translate(0f, dy)
                    canvas.nativeCanvas.drawPath(path, paint)
                    canvas.nativeCanvas.restore()
                }
            }
        }
        // The viewport geometry is read in draw: a State change only triggers a redraw
        val anchor = viewport
        val viewportHeight = anchor?.height ?: 0f
        val span = if (anchor != null && viewportHeight > 0f && !topInWindow.isNaN()) {
            OriveoUserBubble.span(viewportHeight, topInWindow - anchor.top)
        } else {
            UserBubbleSpan(0f, size.height)
        }
        outline?.let { drawOutline(it, current.brush(span)) }
        if (decorated) highlightPath?.let { drawPath(it, current.highlightColor) }
        drawContent()
    }
}
