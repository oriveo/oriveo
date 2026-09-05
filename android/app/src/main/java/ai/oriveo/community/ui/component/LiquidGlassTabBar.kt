package ai.oriveo.community.ui.component

import androidx.compose.animation.animateColor
import androidx.compose.animation.core.animateDp
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

@androidx.compose.runtime.Immutable
data class LiquidGlassTabBarItem(
    val label: String,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector = selectedIcon,
    
    val selectedTint: Color = Color.Unspecified,
    val selected: Boolean,
    val onClick: () -> Unit,
)

internal data class LiquidGlassTabBarLayoutMetrics(
    val barHeight: Dp,
    
    
    
    val maxBarWidth: Dp,
    val outerHorizontalInset: Dp,
    val outerVerticalInset: Dp,
    val itemHorizontalPadding: Dp,
    val itemTopPadding: Dp,
    val itemBottomPadding: Dp,
    val iconSize: Dp,
    val labelTopSpacing: Dp,
    val labelFontSize: TextUnit,
    val selectedContentOffsetY: Dp,
    val capsuleWidthFraction: Float,
) {
    
    val labelLineHeight: TextUnit get() = (labelFontSize.value * 1.25f).sp
}

internal data class LiquidGlassCapsuleBounds(
    val left: Dp,
    val right: Dp,
    val width: Dp,
)

internal fun liquidGlassTabBarLayoutMetrics(isCompact: Boolean): LiquidGlassTabBarLayoutMetrics {
    return if (isCompact) {
        
        
        LiquidGlassTabBarLayoutMetrics(
            barHeight = 58.dp,
            maxBarWidth = 288.dp,
            outerHorizontalInset = 9.dp,
            outerVerticalInset = 2.5.dp,
            itemHorizontalPadding = 5.dp,
            itemTopPadding = 7.dp,
            itemBottomPadding = 6.5.dp,
            iconSize = 23.dp,
            labelTopSpacing = 1.5.dp,
            labelFontSize = 10.sp,
            selectedContentOffsetY = (-1.5).dp,
            capsuleWidthFraction = 0.88f,
        )
    } else {
        LiquidGlassTabBarLayoutMetrics(
            barHeight = 62.dp,
            maxBarWidth = 300.dp,
            outerHorizontalInset = 10.dp,
            outerVerticalInset = 3.dp,
            itemHorizontalPadding = 6.dp,
            itemTopPadding = 7.5.dp,
            itemBottomPadding = 7.dp,
            iconSize = 25.dp,
            labelTopSpacing = 2.dp,
            labelFontSize = 10.5.sp,
            selectedContentOffsetY = (-1.5).dp,
            capsuleWidthFraction = 0.9f,
        )
    }
}

internal fun resolveLiquidGlassCapsuleBounds(
    totalWidth: Dp,
    itemCount: Int,
    selectedIndex: Int,
    metrics: LiquidGlassTabBarLayoutMetrics,
): LiquidGlassCapsuleBounds {
    val safeItemCount = itemCount.coerceAtLeast(1)
    val clampedIndex = selectedIndex.coerceIn(0, safeItemCount - 1)
    val contentWidth = totalWidth - metrics.outerHorizontalInset * 2
    val segmentWidth = contentWidth / safeItemCount.toFloat()
    val capsuleWidth = segmentWidth * metrics.capsuleWidthFraction
    val capsuleLeft = metrics.outerHorizontalInset +
        segmentWidth * clampedIndex.toFloat() +
        (segmentWidth - capsuleWidth) / 2
    val capsuleRight = capsuleLeft + capsuleWidth

    return LiquidGlassCapsuleBounds(
        left = capsuleLeft,
        right = capsuleRight,
        width = capsuleWidth,
    )
}

@Composable
fun LiquidGlassTabBar(
    items: List<LiquidGlassTabBarItem>,
    modifier: Modifier = Modifier,
) {
    if (items.isEmpty()) return

    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val palette = remember(isDark, colors) { liquidGlassPalette(colors, isDark) }
    val metrics = liquidGlassTabBarLayoutMetrics(OriveoTheme.layout.isCompact)
    val selectedIndex = items.indexOfFirst { it.selected }.let { if (it >= 0) it else 0 }
    var previousSelectedIndex by remember { mutableIntStateOf(selectedIndex) }

    
    val interactionSources = remember(items.size) {
        List(items.size) { MutableInteractionSource() }
    }
    val selectedPressed by interactionSources[selectedIndex].collectIsPressedAsState()
    val capsulePressScale by animateFloatAsState(
        targetValue = if (selectedPressed) 0.97f else 1f,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = 500f),
        label = "tabBarCapsulePressScale",
    )

    BoxWithConstraints(
        modifier = modifier.height(metrics.barHeight),
    ) {
        val barShape = RoundedCornerShape(metrics.barHeight / 2)
        val sideInset = metrics.outerHorizontalInset
        val verticalInset = metrics.outerVerticalInset
        val capsuleHeight = maxHeight - verticalInset * 2
        val capsuleShape = RoundedCornerShape(capsuleHeight / 2)
        val targetBounds = resolveLiquidGlassCapsuleBounds(
            totalWidth = maxWidth,
            itemCount = items.size,
            selectedIndex = selectedIndex,
            metrics = metrics,
        )
        val movementDirection = (selectedIndex - previousSelectedIndex).compareTo(0)
        val capsuleLeft by animateDpAsState(
            targetValue = targetBounds.left,
            animationSpec = spring(
                dampingRatio = 0.78f,
                stiffness = when {
                    movementDirection > 0 -> 260f
                    movementDirection < 0 -> 220f
                    else -> 260f
                },
            ),
            label = "tabBarCapsuleLeft",
        )
        val capsuleRight by animateDpAsState(
            targetValue = targetBounds.right,
            animationSpec = spring(
                dampingRatio = 0.78f,
                stiffness = when {
                    movementDirection > 0 -> 220f
                    movementDirection < 0 -> 260f
                    else -> 260f
                },
            ),
            label = "tabBarCapsuleRight",
        )
        val capsuleWidth = capsuleRight - capsuleLeft

        LaunchedEffect(selectedIndex) {
            previousSelectedIndex = selectedIndex
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .shadow(
                    elevation = if (isDark) 8.dp else 6.dp,
                    shape = barShape,
                    ambientColor = palette.barShadow,
                    spotColor = palette.barShadow,
                )
                .clip(barShape)
                .background(
                    brush = Brush.verticalGradient(palette.barFill),
                )
                .border(
                    width = 0.5.dp,
                    color = palette.barBorder,
                    shape = barShape,
                ),
        )

        
        Box(
            modifier = Modifier
                .offset(x = capsuleLeft, y = verticalInset)
                .width(capsuleWidth)
                .height(capsuleHeight)
                .graphicsLayer {
                    scaleX = capsulePressScale
                    scaleY = capsulePressScale
                }
                .shadow(
                    elevation = if (isDark) 4.dp else 2.dp,
                    shape = capsuleShape,
                    ambientColor = palette.capsuleShadow,
                    spotColor = palette.capsuleShadow,
                )
                .clip(capsuleShape)
                .background(color = palette.capsuleFill)
                .border(
                    width = 0.5.dp,
                    color = palette.capsuleBorder,
                    shape = capsuleShape,
                ),
        )

        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = sideInset, vertical = verticalInset)
                .selectableGroup(),
        ) {
            items.forEachIndexed { index, item ->
                LiquidGlassTabBarButton(
                    item = item,
                    metrics = metrics,
                    palette = palette,
                    interactionSource = interactionSources[index],
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                )
            }
        }
    }
}

@Composable
private fun LiquidGlassTabBarButton(
    item: LiquidGlassTabBarItem,
    metrics: LiquidGlassTabBarLayoutMetrics,
    palette: LiquidGlassPalette,
    interactionSource: MutableInteractionSource,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val isPressed by interactionSource.collectIsPressedAsState()

    
    val selectedColor = if (item.selectedTint != Color.Unspecified) item.selectedTint else palette.selectedContent

    
    val pressScale by animateFloatAsState(
        targetValue = if (isPressed) 0.95f else 1f,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = 500f),
        label = "tabBarPressScale",
    )

    val transition = updateTransition(targetState = item.selected, label = "tabBarItemSelected")
    val contentSpring = spring<Dp>(dampingRatio = 0.80f, stiffness = 300f)
    val iconSpring = spring<Float>(dampingRatio = 0.72f, stiffness = 300f)
    val fadeTween = tween<Float>(durationMillis = 160)

    val labelColor by transition.animateColor(
        transitionSpec = { tween(durationMillis = 180) },
        label = "tabBarLabelColor",
    ) { selected -> if (selected) selectedColor else palette.unselectedContent }

    val contentOffsetY by transition.animateDp(
        transitionSpec = { contentSpring },
        label = "tabBarContentOffset",
    ) { selected -> if (selected) metrics.selectedContentOffsetY else 0.dp }

    val selectedIconAlpha by transition.animateFloat(
        transitionSpec = { fadeTween },
        label = "tabBarSelectedIconAlpha",
    ) { selected -> if (selected) 1f else 0f }

    val unselectedIconAlpha by transition.animateFloat(
        transitionSpec = { fadeTween },
        label = "tabBarUnselectedIconAlpha",
    ) { selected -> if (selected) 0f else 1f }

    val selectedIconScale by transition.animateFloat(
        transitionSpec = { iconSpring },
        label = "tabBarSelectedIconScale",
    ) { selected -> if (selected) 1f else 0.88f }

    val unselectedIconScale by transition.animateFloat(
        transitionSpec = { iconSpring },
        label = "tabBarUnselectedIconScale",
    ) { selected -> if (selected) 0.9f else 1f }

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(18.dp))
            .selectable(
                selected = item.selected,
                interactionSource = interactionSource,
                indication = null,
                role = Role.Tab,
                onClick = {
                    if (!item.selected) {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    }
                    item.onClick()
                },
            )
            .semantics {
                contentDescription = item.label
            }
            .padding(
                start = metrics.itemHorizontalPadding,
                end = metrics.itemHorizontalPadding,
                top = metrics.itemTopPadding,
                bottom = metrics.itemBottomPadding,
            )
            .offset(y = contentOffsetY)
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier.size(metrics.iconSize),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = item.unselectedIcon,
                contentDescription = null,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        alpha = unselectedIconAlpha
                        scaleX = unselectedIconScale
                        scaleY = unselectedIconScale
                    },
                tint = palette.unselectedContent,
            )
            Icon(
                imageVector = item.selectedIcon,
                contentDescription = null,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        alpha = selectedIconAlpha
                        scaleX = selectedIconScale
                        scaleY = selectedIconScale
                    },
                tint = selectedColor,
            )
        }
        Spacer(modifier = Modifier.height(metrics.labelTopSpacing))
        Text(
            text = item.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = OriveoTheme.typography.footnote.copy(
                fontSize = metrics.labelFontSize,
                lineHeight = metrics.labelLineHeight,
                letterSpacing = 0.sp,
            ),
            fontWeight = if (item.selected) FontWeight.SemiBold else FontWeight.Medium,
            color = labelColor,
        )
    }
}

private data class LiquidGlassPalette(
    val barFill: List<Color>,
    val barBorder: Color,
    val barShadow: Color,
    val capsuleFill: Color,
    val capsuleBorder: Color,
    val capsuleShadow: Color,
    val selectedContent: Color,
    val unselectedContent: Color,
)

private fun liquidGlassPalette(
    colors: OriveoColors,
    isDark: Boolean,
): LiquidGlassPalette {
    return if (isDark) {
        LiquidGlassPalette(
            
            barFill = listOf(
                Color(0xE81C2438),
                Color(0xDE161E30),
                Color(0xD40E1626),
            ),
            barBorder = Color.White.copy(alpha = 0.10f),
            barShadow = colors.shadowStrong.opacity(0.42f),
            
            capsuleFill = Color.White.copy(alpha = 0.17f),
            capsuleBorder = Color.White.copy(alpha = 0.22f),
            capsuleShadow = Color.Black.copy(alpha = 0.22f),
            selectedContent = colors.primary.copy(alpha = 1f),
            unselectedContent = colors.textPrimary.copy(alpha = 0.58f),
        )
    } else {
        LiquidGlassPalette(
            
            barFill = listOf(
                Color(0xF5FAFBFE),
                Color(0xF0F7F9FD),
                Color(0xECF4F6FB),
            ),
            barBorder = Color.White.copy(alpha = 0.76f),
            barShadow = colors.shadow.opacity(0.12f),
            
            capsuleFill = Color(0xFCFFFFFF),
            capsuleBorder = Color(0x14000000),
            capsuleShadow = Color(0x12000000),
            selectedContent = colors.primary,
            unselectedContent = colors.textPrimary.copy(alpha = 0.66f),
        )
    }
}
