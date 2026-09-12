package ai.oriveo.community.ui.component

import android.os.Build
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.paddingFromBaseline
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.lerp
import ai.oriveo.community.ui.theme.OriveoTheme
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * One item of the floating glass tab bar.
 *
 * @param glyph line glyph: a monochrome template when unselected, the gradient-colored variant when selected (see [OriveoTabBarIcons])
 * @param selectedLabelColor label color when selected (measured from the iOS vibrant rendering: brighter in dark, deeper in light)
 */
@Immutable
data class LiquidGlassTabBarItem(
    val label: String,
    val glyph: OriveoTabGlyph,
    val selectedLabelColor: Color,
)

/**
 * Geometry of the iOS 26 liquid glass tab bar, measured from screenshots (1pt = 1dp; the density
 * correction already maps logical widths one to one): a 62-high capsule with 8 of padding at each end
 * plus 86 per item (274 for three items, shrunk to content and centered); a 94×53 selection lens with
 * a 26.5 corner radius, centered on the item, inset 4.5 top and bottom and concentric with the capsule
 * end; a 24 icon box 12 from the top; a 10dp label whose baseline sits 13 below the icon box.
 */
internal object LiquidGlassTabBarMetrics {
    val barHeight = 62.dp
    val endPadding = 8.dp
    val itemWidth = 86.dp
    val lensWidth = 94.dp
    val lensHeight = 53.dp
    val iconSize = 24.dp
    val iconTop = 12.dp
    val labelBaselineFromIconBottom = 13.dp
    val labelSize = 10.dp
    /** The capsule bottom stays at least 21 above the screen bottom, or 8 above the navigation bar when there is one. */
    val minBottomGap = 21.dp
    val navigationBarGap = 8.dp

    /** Press lift: the lens grows about 8 on each side (94×53 → 110×69, spilling above and below the capsule), matching the iOS 26 press bubble. */
    const val LIFT_SCALE_X = 110f / 94f
    const val LIFT_SCALE_Y = 69f / 53f

    fun barWidth(itemCount: Int): Dp = endPadding * 2 + itemWidth * itemCount.coerceAtLeast(1)
}

/** Distance from the capsule bottom to the screen bottom: max(21, navigation bar + 8). */
@Composable
fun liquidGlassTabBarBottomGap(): Dp {
    val navigationBar = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    return maxOf(LiquidGlassTabBarMetrics.minBottomGap, navigationBar + LiquidGlassTabBarMetrics.navigationBarGap)
}

/** Height from the screen bottom to the capsule top (navigation bar included): the space a page must leave for the floating tab bar. */
@Composable
fun liquidGlassTabBarReservedHeight(): Dp = liquidGlassTabBarBottomGap() + LiquidGlassTabBarMetrics.barHeight

/** Backdrop blur is enabled on Android 12L and later only: on 12 the RenderNode does not reliably redraw when the content changes (the chat screen uses the same threshold). */
fun liquidGlassBlurSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S_V2

internal fun liquidGlassItemCenterX(index: Int): Dp =
    LiquidGlassTabBarMetrics.endPadding + LiquidGlassTabBarMetrics.itemWidth * index + LiquidGlassTabBarMetrics.itemWidth / 2

/** Pointer x (dp, relative to the capsule's left edge) → nearest item; dragging past either end lands on the first or last item. */
internal fun liquidGlassIndexAt(xDp: Float, itemCount: Int): Int {
    if (itemCount <= 1) return 0
    val relative = (xDp - LiquidGlassTabBarMetrics.endPadding.value) / LiquidGlassTabBarMetrics.itemWidth.value
    return relative.toInt().coerceIn(0, itemCount - 1)
}

/**
 * Floating liquid glass tab bar, modelled on the iOS 26 system TabView bar.
 *
 * Material: the content behind it is blurred through [hazeState] (a hazeSource attached to the NavHost
 * content layer) and lifted with a very faint white tint that keeps the hue of what is behind, which is
 * how the iOS glass reads over scrolling content; a 1dp rim highlight, plus a soft shadow in light mode.
 * Below Android 12L there is no blur and the bar falls back to a near-opaque measured fill. Edge
 * refraction is deliberately left out: it costs too much for what it adds, so this is blur + lift +
 * highlight only.
 *
 * Selection lens: a neutral glass pill (15% white in dark, 7% black in light) with no stroke and no
 * shadow at rest. Gestures follow iOS: pressing lifts and enlarges the lens; dragging moves it 1:1 with
 * the finger across items; releasing snaps to the item under the finger and switches to it; a tap
 * switches directly and the lens springs over. The whole capsule consumes touches, so a tap between
 * icons or on the capsule edge never falls through to the list underneath.
 */
@Composable
fun LiquidGlassTabBar(
    items: List<LiquidGlassTabBarItem>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    hazeState: HazeState?,
    modifier: Modifier = Modifier,
) {
    if (items.isEmpty()) return
    val isDark = OriveoTheme.isDark
    val haptics = LocalHapticFeedback.current
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    val scope = rememberCoroutineScope()
    val touchSlop = LocalViewConfiguration.current.touchSlop

    val itemCount = items.size
    val clampedSelected = selectedIndex.coerceIn(0, itemCount - 1)
    val barWidth = LiquidGlassTabBarMetrics.barWidth(itemCount)
    val shape = CircleShape

    // Lens center x (in dp): follows the selected item at rest and the finger while dragging
    val lensCenter = remember { Animatable(liquidGlassItemCenterX(clampedSelected).value) }
    val lift = remember { Animatable(0f) }
    var dragging by remember { mutableStateOf(false) }
    val currentSelected by rememberUpdatedState(clampedSelected)
    val currentOnSelect by rememberUpdatedState(onSelect)

    val slideSpec = if (reduceMotion) tween<Float>(0) else spring(dampingRatio = 0.85f, stiffness = 247f)
    LaunchedEffect(clampedSelected) {
        if (!dragging) lensCenter.animateTo(liquidGlassItemCenterX(clampedSelected).value, slideSpec)
    }

    val palette = remember(isDark) { liquidGlassPalette(isDark) }

    Box(
        modifier = modifier
            .width(barWidth)
            .height(LiquidGlassTabBarMetrics.barHeight)
            .selectableGroup()
            .pointerInput(itemCount, reduceMotion) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    down.consume()
                    val startIndex = liquidGlassIndexAt(down.position.x.toDp().value, itemCount)
                    scope.launch {
                        if (reduceMotion) lift.snapTo(1f) else lift.animateTo(1f, spring(dampingRatio = 1f, stiffness = 1000f))
                    }
                    var moved = false
                    var hovered = startIndex
                    var pointerId = down.id
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == pointerId } ?: event.changes.first().also { pointerId = it.id }
                        if (!change.pressed) {
                            change.consume()
                            break
                        }
                        if (!moved && abs(change.position.x - down.position.x) > touchSlop) {
                            moved = true
                            dragging = true
                        }
                        if (moved) {
                            val xDp = change.position.x.toDp().value
                            val min = liquidGlassItemCenterX(0).value
                            val max = liquidGlassItemCenterX(itemCount - 1).value
                            scope.launch { lensCenter.snapTo(xDp.coerceIn(min, max)) }
                            val index = liquidGlassIndexAt(xDp, itemCount)
                            if (index != hovered) {
                                hovered = index
                                haptics.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick)
                            }
                        }
                        if (change.positionChange() != Offset.Zero) change.consume()
                    }
                    val target = if (moved) hovered else startIndex
                    dragging = false
                    scope.launch {
                        if (reduceMotion) lift.snapTo(0f) else lift.animateTo(0f, spring(dampingRatio = 1f, stiffness = 1000f))
                    }
                    scope.launch { lensCenter.animateTo(liquidGlassItemCenterX(target).value, slideSpec) }
                    if (target != currentSelected) {
                        haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                        currentOnSelect(target)
                    }
                }
            },
    ) {
        // The glass fill is its own layer clipped to the capsule; the lens and content are not clipped by it,
        // so the lifted lens can spill outside the capsule as it does on iOS while pressed
        Box(
            modifier = Modifier
                .matchParentSize()
                .then(
                    if (palette.shadowColor != Color.Transparent) {
                        Modifier.dropShadow(
                            shape = shape,
                            shadow = Shadow(radius = 24.dp, color = palette.shadowColor, offset = DpOffset(0.dp, 6.dp)),
                        )
                    } else {
                        Modifier
                    },
                )
                .clip(shape)
                .then(
                    if (hazeState != null) {
                        Modifier.hazeEffect(state = hazeState) {
                            blurEnabled = liquidGlassBlurSupported()
                            blurRadius = 10.dp
                            noiseFactor = 0f
                            backgroundColor = palette.fallbackFill
                            tints = listOf(palette.glassTint)
                            fallbackTint = HazeTint(palette.fallbackFill)
                        }
                    } else {
                        Modifier.drawBehind { drawRect(palette.fallbackFill) }
                    },
                )
                .drawWithContent {
                    drawContent()
                    // 1dp rim highlight (bright at the top, dark at the bottom): the edge the glass material has by itself, not a decorative stroke
                    val stroke = 1.dp.toPx()
                    drawRoundRect(
                        brush = Brush.verticalGradient(listOf(palette.rimTop, palette.rimBottom)),
                        topLeft = Offset(stroke / 2f, stroke / 2f),
                        size = Size(size.width - stroke, size.height - stroke),
                        cornerRadius = CornerRadius((size.height - stroke) / 2f),
                        style = Stroke(width = stroke),
                    )
                },
        )
        LiquidGlassLens(
            centerX = lensCenter,
            lift = lift,
            color = palette.lensFill,
            liftedRim = palette.liftedLensRim,
        )
        items.forEachIndexed { index, item ->
            LiquidGlassTabItem(
                item = item,
                selected = index == clampedSelected,
                isDark = isDark,
                unselectedColor = palette.unselectedContent,
                onClick = { if (index != currentSelected) currentOnSelect(index) },
                modifier = Modifier.offset(x = LiquidGlassTabBarMetrics.endPadding + LiquidGlassTabBarMetrics.itemWidth * index),
            )
        }
    }
}

/**
 * Selection lens: a neutral glass pill at rest (no stroke, no shadow). While pressed it lifts and grows,
 * its fill fades and a rim highlight lights up, so it reads as a clear glass bubble that spills above and
 * below the capsule, matching the iOS press bubble.
 */
@Composable
private fun LiquidGlassLens(
    centerX: Animatable<Float, AnimationVector1D>,
    lift: Animatable<Float, AnimationVector1D>,
    color: Color,
    liftedRim: Color,
) {
    Box(
        modifier = Modifier
            .size(LiquidGlassTabBarMetrics.lensWidth, LiquidGlassTabBarMetrics.lensHeight)
            .graphicsLayer {
                // Translation and scale are read in the draw phase, so dragging and the spring never recompose
                translationX = (centerX.value.dp - LiquidGlassTabBarMetrics.lensWidth / 2).toPx()
                translationY = ((LiquidGlassTabBarMetrics.barHeight - LiquidGlassTabBarMetrics.lensHeight) / 2).toPx()
                val l = lift.value
                scaleX = lerp(1f, LiquidGlassTabBarMetrics.LIFT_SCALE_X, l)
                scaleY = lerp(1f, LiquidGlassTabBarMetrics.LIFT_SCALE_Y, l)
            }
            .drawBehind {
                val l = lift.value
                val radius = CornerRadius(size.height / 2f)
                drawRoundRect(color = color, cornerRadius = radius, alpha = lerp(1f, 0.55f, l))
                if (l > 0f) {
                    val stroke = 1.dp.toPx()
                    drawRoundRect(
                        color = liftedRim,
                        topLeft = Offset(stroke / 2f, stroke / 2f),
                        size = Size(size.width - stroke, size.height - stroke),
                        cornerRadius = CornerRadius((size.height - stroke) / 2f),
                        alpha = l,
                        style = Stroke(width = stroke),
                    )
                }
            },
    )
}

@Composable
private fun LiquidGlassTabItem(
    item: LiquidGlassTabBarItem,
    selected: Boolean,
    isDark: Boolean,
    unselectedColor: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val labelColor by animateColorAsState(
        targetValue = if (selected) item.selectedLabelColor else unselectedColor,
        animationSpec = tween(durationMillis = 200),
        label = "tabBarLabelColor",
    )
    val labelSize = with(LocalDensity.current) { LiquidGlassTabBarMetrics.labelSize.toSp() }
    Box(
        modifier = modifier
            .width(LiquidGlassTabBarMetrics.itemWidth)
            .fillMaxHeight()
            // Touch is handled by the capsule as a whole (drag to select); this only exposes one activatable Tab node to TalkBack, named by the visible label
            .semantics(mergeDescendants = true) {
                role = Role.Tab
                this.selected = selected
                onClick {
                    onClick()
                    true
                }
            },
    ) {
        Icon(
            imageVector = if (selected) {
                OriveoTabBarIcons.selected(item.glyph, isDark)
            } else {
                OriveoTabBarIcons.template(item.glyph)
            },
            contentDescription = null,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = LiquidGlassTabBarMetrics.iconTop)
                .size(LiquidGlassTabBarMetrics.iconSize),
            tint = if (selected) Color.Unspecified else unselectedColor,
        )
        // The label does not scale with the system font size (same as the iOS tab bar): the capsule height is fixed, so a larger label would only be clipped
        Text(
            text = item.label,
            color = labelColor,
            fontSize = labelSize,
            lineHeight = labelSize * 1.2f,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            softWrap = false,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(horizontal = 4.dp)
                .paddingFromBaseline(
                    top = LiquidGlassTabBarMetrics.iconTop +
                        LiquidGlassTabBarMetrics.iconSize +
                        LiquidGlassTabBarMetrics.labelBaselineFromIconBottom,
                ),
        )
    }
}

private data class LiquidGlassPalette(
    /** Lift layer over the blur (about +12/255 per channel as measured on iOS, keeps the hue behind) */
    val glassTint: HazeTint,
    /** Near-opaque fill used without blur (below 12L), the composited glass color measured on iOS */
    val fallbackFill: Color,
    val rimTop: Color,
    val rimBottom: Color,
    val lensFill: Color,
    /** Rim highlight of the lifted lens while pressed */
    val liftedLensRim: Color,
    val unselectedContent: Color,
    val shadowColor: Color,
)

private fun liquidGlassPalette(isDark: Boolean): LiquidGlassPalette = if (isDark) {
    LiquidGlassPalette(
        glassTint = HazeTint(Color.White.copy(alpha = 0.06f), BlendMode.SrcOver),
        fallbackFill = Color(0xF2211F2B),
        rimTop = Color.White.copy(alpha = 0.16f),
        rimBottom = Color.White.copy(alpha = 0.06f),
        lensFill = Color.White.copy(alpha = 0.15f),
        liftedLensRim = Color.White.copy(alpha = 0.32f),
        unselectedContent = Color.White,
        shadowColor = Color.Transparent,
    )
} else {
    LiquidGlassPalette(
        glassTint = HazeTint(Color.White.copy(alpha = 0.65f), BlendMode.SrcOver),
        fallbackFill = Color(0xF7FDFBFF),
        rimTop = Color.White.copy(alpha = 0.9f),
        rimBottom = Color.White.copy(alpha = 0.5f),
        lensFill = Color.Black.copy(alpha = 0.07f),
        liftedLensRim = Color.White.copy(alpha = 0.95f),
        unselectedContent = Color.Black,
        shadowColor = Color(0xFF0F172A).copy(alpha = 0.12f),
    )
}
