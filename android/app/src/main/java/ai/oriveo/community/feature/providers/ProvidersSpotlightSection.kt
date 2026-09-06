package ai.oriveo.community.feature.providers

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material3.Text
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun ProvidersSpotlightSection(
    providers: List<Provider>,
    costForProvider: (Provider) -> Double,
    dailyCostsForProvider: (Provider) -> List<Double>,

    availableModelCountForProvider: (Provider) -> Int,
    onProviderTap: (Provider) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (providers.isEmpty()) return

    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ProvidersSectionHeader(
            text = stringResource(R.string.providers_active_this_month),
            icon = Icons.Outlined.AutoAwesome,
            tone = ProvidersSectionHeaderTone.Active,
        )

        if (providers.size == 1) {
            val p = providers[0]
            ProviderHeroCard(
                provider = p,
                monthlyEstimatedCost = costForProvider(p),
                availableModelCount = availableModelCountForProvider(p),
                dailyCostsLast7Days = dailyCostsForProvider(p),
                onClick = { onProviderTap(p) },
            )
        } else {
            SpotlightCarousel(
                providers = providers,
                costForProvider = costForProvider,
                dailyCostsForProvider = dailyCostsForProvider,
                availableModelCountForProvider = availableModelCountForProvider,
                onProviderTap = onProviderTap,
            )
        }
    }
}

enum class ProvidersSectionHeaderTone {
    Active,
    All,
    Costs,
}

@Composable
fun ProvidersSectionHeader(
    text: String,
    icon: ImageVector,
    tone: ProvidersSectionHeaderTone,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val accent = when (tone) {
        ProvidersSectionHeaderTone.Active -> colors.success
        ProvidersSectionHeaderTone.All -> colors.info
        ProvidersSectionHeaderTone.Costs -> colors.warning
    }
    Row(
        modifier = modifier.padding(start = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {

        Box(
            modifier = Modifier.size(20.dp),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = accent,
            )
        }

        Text(
            text = text,
            style = compactTextStyle(
                TextStyle(
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 18.sp,
                    letterSpacing = 0.sp,
                ),
            ),
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SpotlightCarousel(
    providers: List<Provider>,
    costForProvider: (Provider) -> Double,
    dailyCostsForProvider: (Provider) -> List<Double>,
    availableModelCountForProvider: (Provider) -> Int,
    onProviderTap: (Provider) -> Unit,
) {
    val pagerState = rememberPagerState(pageCount = { providers.size })
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HorizontalPager(state = pagerState) { page ->
            val p = providers[page]
            ProviderHeroCard(
                provider = p,
                monthlyEstimatedCost = costForProvider(p),
                availableModelCount = availableModelCountForProvider(p),
                dailyCostsLast7Days = dailyCostsForProvider(p),
                onClick = { onProviderTap(p) },
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            providers.indices.forEach { i ->
                val isCurrent = i == pagerState.currentPage
                val width by animateDpAsState(
                    targetValue = if (isCurrent) 18.dp else 6.dp,
                    animationSpec = spring(dampingRatio = 0.85f, stiffness = 600f),
                    label = "indicator-width",
                )
                val color = if (isCurrent) {
                    OriveoTheme.colors.textPrimary.copy(alpha = 0.78f)
                } else {
                    OriveoTheme.colors.textTertiary.copy(alpha = 0.35f)
                }
                Box(
                    modifier = Modifier
                        .padding(horizontal = 3.dp)
                        .requiredWidth(width)
                        .requiredHeight(6.dp)
                        .clip(CircleShape)
                        .background(color),
                )
            }
        }
    }
}

private fun compactTextStyle(base: TextStyle): TextStyle =
    base.copy(
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.Both,
        ),
    )
