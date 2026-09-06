package ai.oriveo.community.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderEffectiveStatusKind
import ai.oriveo.community.core.model.effectiveStatusKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.resolveProviderLogoKind
import ai.oriveo.community.ui.component.OriveoStatusDot
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.brandWatermarkIcon
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.ProviderBadgeColors
import ai.oriveo.community.ui.util.formatRelativeTime
import kotlin.math.max

@Composable
fun ProviderHeroCard(
    provider: Provider,
    monthlyEstimatedCost: Double,

    availableModelCount: Int,
    dailyCostsLast7Days: List<Double> = emptyList(),
    onClick: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val resolvedLogoKind = remember(provider) { resolveProviderLogoKind(provider) }
    val resolvedRelayKind = remember(provider, resolvedLogoKind) {
        if (provider.kind == ProviderKind.Relay && resolvedLogoKind == ProviderKind.Relay) {
            provider.relayKind
        } else {
            null
        }
    }

    val brandColor = if (resolvedLogoKind == ProviderKind.Relay) {
        OriveoTheme.colors.primary
    } else {
        ProviderBadgeColors.usageBreakdown(resolvedLogoKind)
    }

    val subduedBrand = remember(brandColor, resolvedLogoKind) {
        if (resolvedLogoKind == ProviderKind.Grok) {
            Color(0xFF2E3036)
        } else {
            brandColor.hsbAdjusted(saturation = 0.62f, brightness = 0.88f)
        }
    }
    val gradientStart = remember(subduedBrand) { subduedBrand.blendedWith(Color.White, 0.06f) }
    val gradientEnd = remember(subduedBrand) { subduedBrand.blendedWith(Color.Black, 0.22f) }

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val pressScale = if (isPressed) 0.97f else 1f

    val effective = provider.effectiveStatusKind
    val statusColor = when (effective) {
        ProviderEffectiveStatusKind.Connected -> Color(0xFF5CF5A8)
        ProviderEffectiveStatusKind.Syncing -> Color.White
        ProviderEffectiveStatusKind.Issue, ProviderEffectiveStatusKind.NeedsKey -> Color(0xFFFFD156)
    }
    val statusIsPulsing = effective == ProviderEffectiveStatusKind.Syncing
    val statusText = when (effective) {
        ProviderEffectiveStatusKind.Connected -> stringResource(R.string.status_connected)
        ProviderEffectiveStatusKind.Syncing -> stringResource(R.string.status_syncing)
        ProviderEffectiveStatusKind.Issue -> stringResource(R.string.status_issue)
        ProviderEffectiveStatusKind.NeedsKey -> stringResource(R.string.needs_api_key)
    }

    val shouldDisplayCost = provider.kind != ProviderKind.OpenAI
    val isZeroCost = monthlyEstimatedCost <= CostFormatter.COST_EPSILON
    val monthlyCostText = remember(monthlyEstimatedCost) {
        val formatted = CostFormatter.format(monthlyEstimatedCost)
        if (formatted.isBlank()) "$0" else formatted
    }

    val isAggregatedMismatch = provider.kind.isAggregatedProvider &&
        provider.enabledModelCount != availableModelCount
    val modelsText = if (isAggregatedMismatch) {
        stringResource(R.string.models_added_count, provider.enabledModelCount)
    } else {
        stringResource(R.string.models_count, availableModelCount)
    }
    val neverText = stringResource(R.string.never)
    val syncRelativeText = remember(provider.lastCheckedAt, neverText) {
        provider.lastCheckedAt?.let(::formatRelativeTime) ?: neverText
    }

    val subInfoText = remember(modelsText, provider.lastCheckedAt, syncRelativeText) {
        if (provider.lastCheckedAt == null) modelsText
        else "$modelsText  ·  $syncRelativeText"
    }

    val primaryModelName = remember(provider) {
        val candidate = provider.models.firstOrNull { it.isDefault && it.isAvailable }
            ?: provider.models.firstOrNull { it.isAvailable }
            ?: provider.models.firstOrNull()
        candidate?.let {
            val raw = it.name.ifEmpty { it.id }
            shortenedModelName(raw)
        }
    }

    val resolvedWeekly = remember(dailyCostsLast7Days, monthlyEstimatedCost) {
        resolveWeeklyCosts(dailyCostsLast7Days, monthlyEstimatedCost)
    }
    val hasWeeklySignal = resolvedWeekly.any { it > CostFormatter.COST_EPSILON }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .graphicsLayer { scaleX = pressScale; scaleY = pressScale }
            .shadow(
                elevation = 12.dp,
                shape = RoundedCornerShape(24.dp),
                ambientColor = Color.Black.copy(alpha = if (isDark) 0.35f else 0.10f),
                spotColor = Color.Black.copy(alpha = if (isDark) 0.35f else 0.10f),
            )
            .clip(RoundedCornerShape(24.dp))
            .clickable(interactionSource = interactionSource, indication = null, onClick = onClick),

    ) {
        HeroBackground(gradientStart = gradientStart, gradientEnd = gradientEnd, modifier = Modifier.matchParentSize())
        HeroWatermark(resolvedLogoKind = resolvedLogoKind, modifier = Modifier.matchParentSize())

        Row(
            modifier = Modifier
                .fillMaxWidth()

                .height(IntrinsicSize.Min)
                .padding(horizontal = 20.dp, vertical = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            HeroIdentityColumn(
                resolvedLogoKind = resolvedLogoKind,
                resolvedRelayKind = resolvedRelayKind,
                name = provider.displayName,
                primaryModelName = primaryModelName,
                subInfoText = subInfoText,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
            HeroStatsColumn(
                statusColor = statusColor,
                statusText = statusText,
                statusIsPulsing = statusIsPulsing,
                shouldDisplayCost = shouldDisplayCost,
                monthlyCostText = monthlyCostText,
                isZeroCost = isZeroCost,
                hasWeeklySignal = hasWeeklySignal,
                weekly = resolvedWeekly,
                modifier = Modifier.fillMaxHeight(),
            )
        }

        Box(
            modifier = Modifier
                .matchParentSize()
                .border(
                    width = 0.6.dp,

                    color = Color.White.copy(alpha = if (isDark) 0.08f else 0.55f),
                    shape = RoundedCornerShape(24.dp),
                ),
        )
    }
}

@Composable
private fun HeroBackground(gradientStart: Color, gradientEnd: Color, modifier: Modifier = Modifier) {

    val baseBrush = remember(gradientStart, gradientEnd) {
        Brush.linearGradient(
            colors = listOf(gradientStart, gradientEnd),
            start = Offset(0f, 0f),
            end = Offset.Infinite,
        )
    }
    val specularBrush = remember {
        Brush.radialGradient(
            colors = listOf(Color.White.copy(alpha = 0.16f), Color.Transparent),
            center = Offset(Float.POSITIVE_INFINITY, 0f),
            radius = 360f,
        )
    }
    val bottomDimBrush = remember {
        Brush.verticalGradient(
            colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.18f)),
            startY = 0f,
        )
    }
    val sheenBrush = remember {
        Brush.linearGradient(
            colors = listOf(
                Color.White.copy(alpha = 0f),
                Color.White.copy(alpha = 0.06f),
                Color.White.copy(alpha = 0f),
            ),
            start = Offset(60f, -30f),
            end = Offset(120f, 360f),
        )
    }

    Box(modifier = modifier) {

        Box(modifier = Modifier.fillMaxSize().background(baseBrush))

        Box(modifier = Modifier.fillMaxSize().background(specularBrush))

        Box(modifier = Modifier.fillMaxSize().background(bottomDimBrush))

        Box(modifier = Modifier.fillMaxSize().background(sheenBrush))
    }
}

@Composable
private fun HeroWatermark(resolvedLogoKind: ProviderKind, modifier: Modifier = Modifier) {
    val watermarkSymbol = resolvedLogoKind.brandWatermarkIcon()
    Box(
        modifier = modifier,
        contentAlignment = Alignment.BottomEnd,
    ) {
        Box(
            modifier = Modifier
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints)
                    layout(placeable.width, placeable.height) {

                        placeable.placeRelative(35.dp.roundToPx(), 20.dp.roundToPx())
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            if (watermarkSymbol != null) {

                Icon(
                    imageVector = watermarkSymbol,
                    contentDescription = null,
                    modifier = Modifier.size(124.dp),
                    tint = Color.White.copy(alpha = 0.10f),
                )
            } else {

                Box(
                    modifier = Modifier
                        .size(150.dp)
                        .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                        .drawWithContent {
                            drawContent()
                            drawRect(
                                color = Color.White.copy(alpha = 0.10f),
                                blendMode = BlendMode.SrcIn,
                            )
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    ProviderBadgeIcon(kind = resolvedLogoKind, size = 150.dp)
                }
            }
        }
    }
}

@Composable
private fun HeroIdentityColumn(
    resolvedLogoKind: ProviderKind,
    resolvedRelayKind: ai.oriveo.community.core.model.RelayKind?,
    name: String,
    primaryModelName: String?,
    subInfoText: String,
    modifier: Modifier = Modifier,
) {

    val logoTile = 38.dp
    Column(modifier = modifier) {
        ProviderBadgeIcon(
            kind = resolvedLogoKind,
            size = logoTile,
            relayKind = resolvedRelayKind,
            forceDarkAppearance = true,
            contentScaleOverride = 1f,
        )

        var nameFontSize by remember(name) { mutableStateOf(26f) }
        Text(
            text = name,
            modifier = Modifier.padding(top = 12.dp),
            style = compactTextStyle(
                TextStyle(
                    fontSize = nameFontSize.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = (nameFontSize * 1.08f).sp,
                    letterSpacing = (-0.4).sp,
                ),
            ),
            color = Color.White,
            maxLines = 1,
            softWrap = false,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { result ->
                if (result.didOverflowWidth && nameFontSize > 18f) {
                    nameFontSize = (nameFontSize * 0.92f).coerceAtLeast(18f)
                }
            },
        )

        Column(
            modifier = Modifier.padding(top = 8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (primaryModelName != null) {
                HeroModelRow(modelName = primaryModelName)
            }
            Text(
                text = subInfoText,
                style = compactTextStyle(
                    TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, lineHeight = 14.sp),
                ),
                color = Color.White.copy(alpha = 0.72f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        Spacer(modifier = Modifier.weight(1f))
    }
}

@Composable
private fun HeroStatsColumn(
    statusColor: Color,
    statusText: String,
    statusIsPulsing: Boolean,
    shouldDisplayCost: Boolean,
    monthlyCostText: String,
    isZeroCost: Boolean,
    hasWeeklySignal: Boolean,
    weekly: List<Double>,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier, horizontalAlignment = Alignment.End) {

        Row(
            modifier = Modifier
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.22f))
                .padding(horizontal = 9.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            OriveoStatusDot(color = statusColor, size = 6.dp, pulsing = statusIsPulsing)
            Text(
                text = statusText,
                style = compactTextStyle(
                    TextStyle(fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, lineHeight = 14.sp),
                ),
                color = Color.White,
                maxLines = 1,
            )
        }

        Spacer(modifier = Modifier.weight(1f))

        HeroCostView(
            shouldDisplayCost = shouldDisplayCost,
            monthlyCostText = monthlyCostText,
            isZeroCost = isZeroCost,
            hasWeeklySignal = hasWeeklySignal,
            weekly = weekly,
        )
    }
}

@Composable
private fun HeroModelRow(modelName: String) {

    val icon = remember(modelName) { ModelFamilyIcon.familyIcon(modelName) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(11.dp),
            tint = Color.White.copy(alpha = 0.85f),
        )
        Text(
            text = modelName,
            style = compactTextStyle(
                TextStyle(
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    lineHeight = 15.sp,
                    letterSpacing = (-0.1).sp,
                ),
            ),
            color = Color.White.copy(alpha = 0.95f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun HeroCostView(
    shouldDisplayCost: Boolean,
    monthlyCostText: String,
    isZeroCost: Boolean,
    hasWeeklySignal: Boolean,
    weekly: List<Double>,
) {
    if (!shouldDisplayCost) {

        Row(
            modifier = Modifier
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.22f))
                .border(width = 0.6.dp, color = Color.White.copy(alpha = 0.30f), shape = CircleShape)
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.AutoAwesome,
                contentDescription = null,
                modifier = Modifier.size(11.dp),
                tint = Color.White,
            )
            Text(
                text = stringResource(R.string.providers_free_pill),
                style = compactTextStyle(
                    TextStyle(
                        fontSize = 11.5.sp,
                        fontWeight = FontWeight.Bold,
                        lineHeight = 13.sp,
                        letterSpacing = 0.6.sp,
                    ),
                ),
                color = Color.White,
                maxLines = 1,
            )
        }
        return
    }

    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                text = stringResource(R.string.this_month).uppercase(),
                style = compactTextStyle(
                    TextStyle(
                        fontSize = 9.5.sp,
                        fontWeight = FontWeight.SemiBold,
                        lineHeight = 11.sp,
                        letterSpacing = 0.8.sp,
                    ),
                ),
                color = Color.White.copy(alpha = 0.65f),
                maxLines = 1,
            )
            Text(
                text = monthlyCostText,
                style = compactTextStyle(
                    TextStyle(
                        fontSize = 28.sp,
                        fontWeight = FontWeight.Bold,
                        lineHeight = 30.sp,
                        fontFeatureSettings = "tnum",
                    ),
                ),
                color = Color.White.copy(alpha = if (isZeroCost) 0.78f else 1.0f),
                maxLines = 1,
            )
        }
        if (hasWeeklySignal) {
            HeroWeeklyBarChart(values = weekly)
        }
    }
}

@Composable
private fun HeroWeeklyBarChart(values: List<Double>) {
    val maxValue = max(values.maxOrNull() ?: 0.0, 0.0001)
    val barWidth: Dp = 8.dp
    val maxHeight: Dp = 24.dp
    val gap: Dp = 5.dp

    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            modifier = Modifier.height(maxHeight),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(gap),
        ) {
            values.forEachIndexed { idx, value ->
                val ratio = (value / maxValue).toFloat().coerceIn(0f, 1f)
                val isLast = idx == values.lastIndex
                val barHeight = max(3f, (maxHeight.value * ratio)).dp
                Box(
                    modifier = Modifier
                        .requiredWidth(barWidth)
                        .requiredHeight(barHeight)
                        .clip(CircleShape)
                        .background(
                            if (isLast) {
                                Brush.verticalGradient(
                                    colors = listOf(Color.White, Color.White.copy(alpha = 0.88f)),
                                )
                            } else {
                                Brush.verticalGradient(
                                    colors = listOf(
                                        Color.White.copy(alpha = 0.38f),
                                        Color.White.copy(alpha = 0.38f),
                                    ),
                                )
                            },
                        ),
                )
            }
        }
        val todayCost = values.lastOrNull() ?: 0.0
        val todayText = remember(todayCost) {
            val formatted = CostFormatter.format(todayCost)
            if (formatted.isBlank()) "$0" else formatted
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = stringResource(R.string.providers_today).uppercase(),
                style = compactTextStyle(
                    TextStyle(
                        fontSize = 9.sp,
                        fontWeight = FontWeight.SemiBold,
                        lineHeight = 11.sp,
                        letterSpacing = 0.6.sp,
                    ),
                ),
                color = Color.White.copy(alpha = 0.55f),
                maxLines = 1,
            )
            Text(
                text = todayText,
                style = compactTextStyle(
                    TextStyle(
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        lineHeight = 12.sp,
                        fontFeatureSettings = "tnum",
                    ),
                ),
                color = Color.White.copy(alpha = 0.92f),
                maxLines = 1,
            )
        }
    }
}

private fun resolveWeeklyCosts(real: List<Double>, monthlyEstimatedCost: Double): List<Double> {
    if (real.isNotEmpty()) return real.takeLast(7)
    if (monthlyEstimatedCost <= CostFormatter.COST_EPSILON) return List(7) { 0.0 }
    val weights = doubleArrayOf(0.45, 0.62, 0.38, 0.78, 0.50, 0.85, 1.00)
    val sum = weights.sum()
    val dailyBudget = monthlyEstimatedCost * 0.32
    return weights.map { (it / sum) * dailyBudget }
}

private fun compactTextStyle(base: TextStyle): TextStyle =
    base.copy(
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.Both,
        ),
    )
