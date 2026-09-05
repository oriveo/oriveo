package ai.oriveo.community.feature.providers

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.CostFormatter

import ai.oriveo.community.core.usage.MonthlyCostProviderEntry
import ai.oriveo.community.core.usage.MonthlyCostSummary
import ai.oriveo.community.ui.component.OriveoFadeHairline
import ai.oriveo.community.ui.component.OriveoIconPlate
import ai.oriveo.community.ui.component.oriveoGradientPanel
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt


@Composable
fun ProvidersCostSummaryCard(
    summary: MonthlyCostSummary,
    modifier: Modifier = Modifier,
    onOpenDetails: (() -> Unit)? = null,
) {
    val isCompact = OriveoTheme.layout.isCompact
    val isDark = OriveoTheme.isDark
    val colors = OriveoTheme.colors

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (onOpenDetails != null && isPressed) 0.98f else 1f,
        animationSpec = tween(150),
        label = "cost-card-scale",
    )
    val alpha by animateFloatAsState(
        targetValue = if (onOpenDetails != null && isPressed) 0.92f else 1f,
        animationSpec = tween(150),
        label = "cost-card-alpha",
    )

    val horizontalPadding = if (isCompact) 14.dp else 18.dp
    val topPadding = if (isCompact) 14.dp else 18.dp
    val bottomPadding = if (isCompact) 12.dp else 16.dp
    val watermarkSize = if (isCompact) 60.dp else 80.dp
    val watermarkOffsetX = if (isCompact) 18.dp else 28.dp
    val watermarkOffsetY = if (isCompact) (-16).dp else (-22).dp

    Box(
        modifier = modifier
            .fillMaxWidth()
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                this.alpha = alpha
            }
            .let {
                if (onOpenDetails != null) {
                    it.clickable(
                        interactionSource = interactionSource,
                        indication = null,
                        onClick = onOpenDetails,
                    )
                } else {
                    it
                }
            }
            .oriveoGradientPanel(radius = 22.dp)
            
            .drawBehind {
                drawBrandSheen(isDark = isDark, primary = colors.primary)
            },
    ) {
        
        Icon(
            imageVector = Icons.Filled.CreditCard,
            contentDescription = null,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .size(watermarkSize)
                .offset(x = watermarkOffsetX, y = watermarkOffsetY)
                .graphicsLayer { rotationZ = -14f },
            tint = colors.primary.copy(alpha = if (isDark) 0.07f else 0.045f),
        )

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = horizontalPadding,
                    end = horizontalPadding,
                    top = topPadding,
                    bottom = bottomPadding,
                ),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            TitleRow(showChevron = onOpenDetails != null)
            HeroBlock(summary = summary, isCompact = isCompact)

            if (summary.providers.isNotEmpty()) {
                
                if (summary.providers.size + summary.hiddenProviderCount >= 2) {
                    SegmentedCostBar(
                        providers = summary.providers,
                        totalCost = summary.totalCost,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                ProviderBreakdownList(
                    providers = summary.providers,
                    totalCost = summary.totalCost,
                    hiddenCount = summary.hiddenProviderCount,
                )
            }
        }
    }
}

// region Title row

@Composable
private fun TitleRow(showChevron: Boolean) {
    val colors = OriveoTheme.colors

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OriveoIconPlate(size = 22.dp, cornerRadius = 7.dp) {
                Icon(
                    imageVector = Icons.AutoMirrored.Outlined.TrendingUp,
                    contentDescription = null,
                    modifier = Modifier.size(11.dp),
                    tint = colors.primary,
                )
            }
            
            Text(
                text = stringResource(R.string.by_provider),
                style = compactTextStyle(
                    TextStyle(
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.5.sp,
                        lineHeight = 14.sp,
                    ),
                ),
                color = colors.textSecondary,
                maxLines = 1,
            )
        }

        if (showChevron) {
            OriveoIconPlate(size = 24.dp, cornerRadius = 8.dp) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    modifier = Modifier.size(10.dp),
                    tint = colors.textSecondary,
                )
            }
        }
    }
}

// endregion

// region Hero block

@Composable
private fun HeroBlock(summary: MonthlyCostSummary, isCompact: Boolean) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val subtitleRes = R.string.based_on_usage_on_this_device

    val fullText = CostFormatter.format(summary.totalCost).ifEmpty { "$0" }
    val hasDollarPrefix = fullText.startsWith("$")
    val dollarBody = if (hasDollarPrefix) fullText.substring(1) else fullText

    
    
    val baseNumberSize = if (isCompact) 28f else 36f
    val numberMinSize = baseNumberSize * 0.7f
    var numberFontSize by remember(dollarBody, baseNumberSize) { mutableStateOf(baseNumberSize) }
    val numberLineHeight = (baseNumberSize * 40f / 36f).sp
    val dollarSize = if (isCompact) 16.sp else 20.sp
    val baselineWidth = if (isCompact) 90.dp else 120.dp

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        MonthChip()

        
        
        Row(
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            if (hasDollarPrefix) {
                Text(
                    text = "$",
                    style = compactTextStyle(
                        OriveoTheme.typography.hero.copy(
                            fontSize = dollarSize,
                            lineHeight = numberLineHeight,
                            fontWeight = FontWeight.Bold,
                        ),
                    ),
                    color = colors.textPrimary,
                    maxLines = 1,
                )
            }
            Text(
                text = dollarBody,
                style = compactTextStyle(
                    OriveoTheme.typography.hero.copy(
                        fontSize = numberFontSize.sp,
                        lineHeight = (numberFontSize * 40f / 36f).sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = (-1.4).sp,
                        fontFeatureSettings = "tnum",
                    ),
                ),
                color = colors.textPrimary,
                maxLines = 1,
                softWrap = false,
                onTextLayout = { result ->
                    if (result.didOverflowWidth && numberFontSize > numberMinSize) {
                        numberFontSize = (numberFontSize * 0.92f).coerceAtLeast(numberMinSize)
                    }
                },
            )
        }

        
        Box(
            modifier = Modifier
                .width(baselineWidth)
                .height(1.5.dp)
                .background(
                    brush = Brush.horizontalGradient(
                        colors = listOf(
                            colors.primary.copy(alpha = if (isDark) 0.68f else 0.55f),
                            colors.primary.copy(alpha = if (isDark) 0.28f else 0.20f),
                            Color.Transparent,
                        ),
                    ),
                ),
        )

        Text(
            text = stringResource(subtitleRes),
            style = compactTextStyle(
                TextStyle(
                    fontWeight = FontWeight.Medium,
                    fontSize = 12.5.sp,
                    lineHeight = 16.sp,
                ),
            ),
            color = colors.textTertiary,
        )
    }
}


@Composable
private fun MonthChip() {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val monthLabel = remember {
        SimpleDateFormat("MMM yyyy", Locale.getDefault()).format(Date()).uppercase(Locale.getDefault())
    }

    Row(
        modifier = Modifier
            .wrapContentSize()
            .clip(CircleShape)
            .background(
                color = colors.primary.copy(alpha = if (isDark) 0.18f else 0.09f),
                shape = CircleShape,
            )
            .border(
                border = BorderStroke(
                    0.6.dp,
                    colors.primary.copy(alpha = if (isDark) 0.32f else 0.18f),
                ),
                shape = CircleShape,
            )
            .padding(horizontal = 9.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(4.dp)
                .background(
                    color = colors.primary.copy(alpha = 0.85f),
                    shape = CircleShape,
                ),
        )
        Text(
            text = monthLabel,
            style = compactTextStyle(
                TextStyle(
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp,
                    lineHeight = 12.sp,
                    letterSpacing = 1.4.sp,
                ),
            ),
            color = colors.primary.copy(alpha = if (isDark) 0.95f else 0.85f),
            maxLines = 1,
        )
    }
}

// endregion

// region Segmented bar


@Composable
private fun SegmentedCostBar(
    providers: List<MonthlyCostProviderEntry>,
    totalCost: Double,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val density = LocalDensity.current

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .height(10.dp),
    ) {
        val totalWidthPx = with(density) { maxWidth.toPx() }
        val count = providers.size
        val gapDp = if (count > 1) 3.dp else 0.dp
        val gapPx = with(density) { gapDp.toPx() }
        val totalGapPx = max(0f, (count - 1).toFloat()) * gapPx
        val usablePx = max(totalWidthPx - totalGapPx, 0f)
        val minSegmentPx = with(density) { 4.dp.toPx() }

        var visibleSharePx = 0f

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(gapDp),
        ) {
            providers.forEachIndexed { index, entry ->
                val share = if (totalCost > 0.0 && totalCost.isFinite()) {
                    (entry.cost / totalCost).toFloat().coerceIn(0f, 1f)
                } else 0f

                if (share > 0f) {
                    val rawPx = usablePx * share
                    val segmentPx = maxOf(rawPx, minSegmentPx)
                    val segmentDp = with(density) { segmentPx.toDp() }
                    visibleSharePx += segmentPx
                    val tint = ChartColorResolver.color(index)
                    SegmentedCostBarPiece(tint = tint, width = segmentDp)
                }
            }

            
            val visibleShareRatio = if (totalWidthPx > 0) visibleSharePx / usablePx else 0f
            if (visibleShareRatio < 0.999f) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .height(10.dp)
                        .clip(CircleShape)
                        .background(
                            color = colors.textTertiary.copy(alpha = if (isDark) 0.10f else 0.07f),
                            shape = CircleShape,
                        ),
                )
            }
        }
    }
}

@Composable
private fun SegmentedCostBarPiece(tint: Color, width: Dp) {
    val isDark = OriveoTheme.isDark
    val shape = CircleShape
    val topHighlightHeight = 3.dp

    Box(
        modifier = Modifier
            .width(width)
            .height(10.dp)
            .clip(shape)
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(lerp(tint, Color.White, 0.06f), tint),
                ),
                shape = shape,
            )
            .border(
                border = BorderStroke(0.5.dp, tint.copy(alpha = if (isDark) 0.45f else 0.32f)),
                shape = shape,
            ),
    ) {
        
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(topHighlightHeight)
                .background(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            Color.White.copy(alpha = if (isDark) 0.16f else 0.22f),
                            Color.Transparent,
                        ),
                    ),
                ),
        )
    }
}

// endregion

// region Provider breakdown list

@Composable
private fun ProviderBreakdownList(
    providers: List<MonthlyCostProviderEntry>,
    totalCost: Double,
    hiddenCount: Int,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        OriveoFadeHairline()
        Spacer(Modifier.height(2.dp))

        providers.forEachIndexed { index, entry ->
            if (index > 0) {
                OriveoFadeHairline(insetLeading = 26.dp)
            }
            ProviderBreakdownRow(
                entry = entry,
                totalCost = totalCost,
                colorIndex = index,
            )
        }

        if (hiddenCount > 0) {
            ProviderBreakdownOverflowRow(hiddenCount = hiddenCount)
        }
    }
}


@Composable
private fun ProviderBreakdownRow(
    entry: MonthlyCostProviderEntry,
    totalCost: Double,
    colorIndex: Int,
) {
    val colors = OriveoTheme.colors
    val chartColor = ChartColorResolver.color(colorIndex)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        
        
        LegendChip(tint = chartColor)

        Text(
            text = entry.displayName,
            modifier = Modifier.weight(1f),
            style = compactTextStyle(
                TextStyle(
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.5.sp,
                    lineHeight = 15.sp,
                    letterSpacing = (-0.07).sp,
                ),
            ),
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = CostFormatter.format(entry.cost),
            style = compactTextStyle(
                TextStyle(
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.5.sp,
                    lineHeight = 15.sp,
                    letterSpacing = (-0.1).sp,
                    fontFeatureSettings = "tnum",
                ),
            ),
            color = colors.textPrimary,
            maxLines = 1,
        )
        Text(
            text = formatProviderShare(entry.cost, totalCost),
            modifier = Modifier.widthIn(min = 36.dp),
            style = compactTextStyle(
                TextStyle(
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 11.5.sp,
                    lineHeight = 13.sp,
                    fontFeatureSettings = "tnum",
                ),
            ),
            color = colors.textTertiary,
            textAlign = TextAlign.End,
            maxLines = 1,
        )
    }
}

@Composable
private fun LegendChip(tint: Color) {
    val isDark = OriveoTheme.isDark
    val shape = CircleShape

    Box(
        modifier = Modifier
            .size(width = 16.dp, height = 7.dp)
            .clip(shape)
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(lerp(tint, Color.White, 0.06f), tint),
                ),
                shape = shape,
            )
            .border(
                border = BorderStroke(0.5.dp, tint.copy(alpha = if (isDark) 0.40f else 0.30f)),
                shape = shape,
            ),
    ) {
        
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(2.dp)
                .background(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            Color.White.copy(alpha = if (isDark) 0.16f else 0.22f),
                            Color.Transparent,
                        ),
                    ),
                ),
        )
    }
}

@Composable
private fun ProviderBreakdownOverflowRow(hiddenCount: Int) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = CircleShape

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        
        Box(
            modifier = Modifier
                .size(width = 16.dp, height = 7.dp)
                .clip(shape)
                .background(
                    color = colors.textTertiary.copy(alpha = if (isDark) 0.22f else 0.14f),
                    shape = shape,
                )
                .border(
                    border = BorderStroke(
                        0.5.dp,
                        colors.textTertiary.copy(alpha = if (isDark) 0.30f else 0.20f),
                    ),
                    shape = shape,
                ),
        )
        Text(
            text = stringResource(R.string.cost_summary_more, hiddenCount),
            style = compactTextStyle(
                TextStyle(
                    fontWeight = FontWeight.Medium,
                    fontSize = 12.sp,
                    lineHeight = 14.sp,
                ),
            ),
            color = colors.textTertiary,
            maxLines = 1,
        )
    }
}

// endregion

// region Brand sheen + chart color resolver


private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawBrandSheen(
    isDark: Boolean,
    primary: Color,
) {
    val topRightCenter = Offset(size.width * 1.0f, 0f)
    val topRightRadius = size.width * 0.75f
    val topRightAlpha = if (isDark) 0.26f else 0.18f
    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(primary.copy(alpha = topRightAlpha), Color.Transparent),
            center = topRightCenter,
            radius = topRightRadius,
        ),
        center = topRightCenter,
        radius = topRightRadius,
    )
    val bottomLeftCenter = Offset(0f, size.height * 1.0f)
    val bottomLeftRadius = size.width * 0.55f
    val bottomLeftAlpha = if (isDark) 0.14f else 0.10f
    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(primary.copy(alpha = bottomLeftAlpha), Color.Transparent),
            center = bottomLeftCenter,
            radius = bottomLeftRadius,
        ),
        center = bottomLeftCenter,
        radius = bottomLeftRadius,
    )
}


private object ChartColorResolver {
    
    private const val BRAND_HUE: Double = 257.0

    
    private val palette = doubleArrayOf(
        15.0,  // coral red       (idx 0)
        160.0, // teal             (idx 1)
        275.0, // violet           (idx 2)
        55.0,  // gold             (idx 3)
        215.0, // ocean blue       (idx 4)
        330.0, // rose             (idx 5)
        130.0, // emerald          (idx 6)
        245.0, // indigo           (idx 7)
        35.0,  // amber orange     (idx 8)
        190.0, // cyan             (idx 9)
        300.0, // magenta          (idx 10)
        355.0, // crimson          (idx 11)
    )

    @Composable
    fun color(index: Int): Color {
        val isDark = OriveoTheme.isDark
        val hue: Float = if (index == 0) {
            (BRAND_HUE / 360.0).toFloat()
        } else {
            val bucket = (((index - 1) % palette.size) + palette.size) % palette.size
            (palette[bucket] / 360.0).toFloat()
        }
        val saturation = if (isDark) 0.50f else 0.55f
        val brightness = if (isDark) 0.82f else 0.88f
        return hsbToColor(hue, saturation, brightness)
    }

    
    private fun hsbToColor(h: Float, s: Float, v: Float): Color {
        val i = (h * 6).toInt()
        val f = h * 6 - i
        val p = v * (1 - s)
        val q = v * (1 - f * s)
        val t = v * (1 - (1 - f) * s)
        return when (i % 6) {
            0 -> Color(red = v, green = t, blue = p)
            1 -> Color(red = q, green = v, blue = p)
            2 -> Color(red = p, green = v, blue = t)
            3 -> Color(red = p, green = q, blue = v)
            4 -> Color(red = t, green = p, blue = v)
            else -> Color(red = v, green = p, blue = q)
        }
    }
}

// endregion

// region Helpers

private fun formatProviderShare(cost: Double, totalCost: Double): String {
    if (!cost.isFinite() || cost <= 0.0 || !totalCost.isFinite() || totalCost <= 0.0) return "0%"
    val sharePercent = (cost / totalCost) * 100.0
    if (sharePercent >= 10.0) return "${sharePercent.roundToInt().coerceAtLeast(1)}%"
    val rounded = ((sharePercent * 10.0).roundToInt() / 10.0).coerceAtLeast(0.1)
    return String.format(Locale.getDefault(), "%.1f%%", rounded)
}

private fun compactTextStyle(base: TextStyle): TextStyle =
    base.copy(
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.Both,
        ),
    )

// endregion
