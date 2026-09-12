package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.translate
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.LocalGraphicsContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.auroraCssShadowRadius
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Per-row appearance of a home conversation group card once the group is split into LazyColumn items (matches
 * iOS AuroraGroupedCard).
 *
 * Background: putting a whole group into one LazyColumn item with `forEach` defeats virtualization. For heavy
 * users, hundreds of conversations from the last 7 days were composed and measured synchronously on the first
 * frame, with main-thread frames of about 13 seconds. So each conversation is its own item and this modifier
 * stitches adjacent items back into one card:
 *  - one card per group, corner radius 20, **no dividers** inside; rows are separated by their own padding only;
 *  - dark #221F35 + a 1dp 5.5% white stroke + a 1px 3% white inner highlight at the top of the first row; light is
 *    pure white + a 1dp 5% black stroke + two very faint shadows;
 *  - the design's 1dp stroke takes space (border-box): content sits 1 + row padding from the card edge.
 *
 * The stroke is drawn as the whole card's rounded rect in each segment's local coordinates and clipped to the
 * segment, so segments join seamlessly. Shadows: each segment casts only its own, after cutting out the card
 * body extended upward / downward across the whole column; otherwise the next segment's shadow would overlap the
 * previous one's bottom and show a seam. Gaussian blur is linear over disjoint shapes, so the side shadows of
 * adjacent segments add up to roughly the whole card's shadow.
 */
internal enum class HomeGroupRowPosition { Single, First, Middle, Last }

internal fun homeGroupRowPosition(index: Int, count: Int): HomeGroupRowPosition = when {
    count <= 1 -> HomeGroupRowPosition.Single
    index == 0 -> HomeGroupRowPosition.First
    index == count - 1 -> HomeGroupRowPosition.Last
    else -> HomeGroupRowPosition.Middle
}

internal val HOME_GROUP_CARD_RADIUS = 20.dp

private val HomeGroupRowPosition.isTop: Boolean
    get() = this == HomeGroupRowPosition.First || this == HomeGroupRowPosition.Single

private val HomeGroupRowPosition.isBottom: Boolean
    get() = this == HomeGroupRowPosition.Last || this == HomeGroupRowPosition.Single

/** Shape of this segment: only the card's real corners are rounded. */
internal fun homeGroupRowShape(position: HomeGroupRowPosition, radius: Dp = HOME_GROUP_CARD_RADIUS): Shape =
    RoundedCornerShape(
        topStart = if (position.isTop) radius else 0.dp,
        topEnd = if (position.isTop) radius else 0.dp,
        bottomStart = if (position.isBottom) radius else 0.dp,
        bottomEnd = if (position.isBottom) radius else 0.dp,
    )

/** The rounded rect of the whole card in this segment's local coordinates: non-first segments extend far upward, non-last segments far downward. */
private fun cardRoundRect(width: Float, height: Float, radius: Float, position: HomeGroupRowPosition, inset: Float = 0f): RoundRect {
    val far = 100_000f
    val corner = CornerRadius((radius - inset).coerceAtLeast(0f))
    return RoundRect(
        left = inset,
        top = if (position.isTop) inset else -far,
        right = width - inset,
        bottom = if (position.isBottom) height - inset else height + far,
        topLeftCornerRadius = if (position.isTop) corner else CornerRadius.Zero,
        topRightCornerRadius = if (position.isTop) corner else CornerRadius.Zero,
        bottomRightCornerRadius = if (position.isBottom) corner else CornerRadius.Zero,
        bottomLeftCornerRadius = if (position.isBottom) corner else CornerRadius.Zero,
    )
}

@Composable
internal fun Modifier.homeGroupedRowSurface(position: HomeGroupRowPosition): Modifier {
    val isDark = OriveoTheme.isDark
    val fill = AuroraTheme.groupCardFill()
    val border = AuroraTheme.groupCardBorder()
    val shape = remember(position) { homeGroupRowShape(position) }
    val shadowContext = LocalGraphicsContext.current.shadowContext
    // Light: 0 1 2 rgba(15,23,42,.04) + 0 6 18 rgba(15,23,42,.04); dark casts no shadow.
    // ShadowContext caches shadow bitmaps by (shape, size, parameters), so rows of equal height share one and scrolling never rebuilds it
    val shadows = remember(shadowContext, shape, isDark) {
        if (isDark) {
            emptyList()
        } else {
            listOf(
                shadowContext.createDropShadowPainter(
                    shape,
                    Shadow(radius = auroraCssShadowRadius(2.dp), color = GROUP_SHADOW_COLOR, offset = DpOffset(0.dp, 1.dp)),
                ),
                shadowContext.createDropShadowPainter(
                    shape,
                    Shadow(radius = auroraCssShadowRadius(18.dp), color = GROUP_SHADOW_COLOR, offset = DpOffset(0.dp, 6.dp)),
                ),
            )
        }
    }
    return this
        .drawWithCache {
            val radius = HOME_GROUP_CARD_RADIUS.toPx()
            val strokeWidth = 1.dp.toPx()
            val bodyPath = Path().apply { addRoundRect(cardRoundRect(size.width, size.height, radius, position)) }
            val borderPath = Path().apply {
                addRoundRect(cardRoundRect(size.width, size.height, radius, position, inset = strokeWidth / 2f))
            }
            // box-shadow: 0 1px 0 rgba(255,255,255,.03) inset: a crescent just inside the stroke at the top (first segment, dark only)
            val highlightPath = if (isDark && position.isTop) {
                val inner = cardRoundRect(size.width, size.height, radius, position, inset = strokeWidth)
                val shifted = inner.translate(Offset(0f, strokeWidth))
                Path().apply {
                    op(Path().apply { addRoundRect(inner) }, Path().apply { addRoundRect(shifted) }, PathOperation.Difference)
                }
            } else {
                null
            }
            onDrawBehind {
                if (shadows.isNotEmpty()) {
                    clipPath(bodyPath, ClipOp.Difference) {
                        shadows.forEach { with(it) { draw(size) } }
                    }
                }
                clipRect {
                    drawPath(bodyPath, fill)
                    drawPath(borderPath, border, style = Stroke(width = strokeWidth))
                    highlightPath?.let { drawPath(it, Color.White.copy(alpha = 0.03f)) }
                }
            }
        }
        // The row's press ripple follows the card corners (shadow and face are drawn above, unaffected by this clip)
        .clip(shape)
        .padding(
            start = 1.dp,
            end = 1.dp,
            top = if (position.isTop) 1.dp else 0.dp,
            bottom = if (position.isBottom) 1.dp else 0.dp,
        )
}

/**
 * Whole-card appearance for non-LazyColumn uses (folder header, expanded folder content): the same face as the group card.
 */
@Composable
internal fun Modifier.homeGroupedCardSurface(): Modifier = homeGroupedRowSurface(HomeGroupRowPosition.Single)

private val GROUP_SHADOW_COLOR = Color(0xFF0F172A).copy(alpha = 0.04f)
