package ai.oriveo.community.feature.providers.detail

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.PieChart
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.NumberFormat
import java.util.Locale

@Composable
fun ProviderBalanceCard(
    state: ProviderDetailViewModel.BalanceUiState,
    providerKind: ProviderKind,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (state is ProviderDetailViewModel.BalanceUiState.Hidden) return

    val colors = OriveoTheme.colors
    val cardShape = RoundedCornerShape(20.dp)
    val isRefreshing = (state is ProviderDetailViewModel.BalanceUiState.Loaded && state.isRefreshing) ||
        state is ProviderDetailViewModel.BalanceUiState.Loading

    Box(
        modifier = modifier
            .fillMaxWidth()
            .shadow(
                elevation = 12.dp,
                shape = cardShape,
                clip = false,
                ambientColor = colors.shadow,
                spotColor = colors.shadow,
            )
            .clip(cardShape)
            .background(colors.surface)
            .drawBehind {

                val radialCenter = Offset(size.width * 1.02f, -size.height * 0.05f)
                drawRect(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            colors.primary.copy(alpha = 0.14f),
                            Color.Transparent,
                        ),
                        center = radialCenter,
                        radius = 240.dp.toPx(),
                    ),
                )

                drawRect(
                    brush = Brush.linearGradient(
                        colors = listOf(
                            Color.White.copy(alpha = 0.0f),
                            Color.White.copy(alpha = 0.06f),
                            Color.White.copy(alpha = 0.0f),
                        ),
                        start = Offset(0f, -size.height * 0.1f),
                        end = Offset(size.width * 0.8f, size.height * 1.2f),
                    ),
                )
            }
            .border(OriveoBorderWidth.standard, colors.border, cardShape),
    ) {

        Box(modifier = Modifier.matchParentSize()) {
            Icon(
                imageVector = Icons.Filled.PieChart,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier
                    .size(130.dp)
                    .align(Alignment.BottomEnd)
                    .offset(x = 30.dp, y = 30.dp)
                    .alpha(0.06f)
                    .rotate(-12f),
            )
        }

        Column(
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            modifier = Modifier
                .fillMaxWidth()
                .padding(OriveoTheme.spacing.lg),
        ) {
            BalanceHeader(
                isRefreshing = isRefreshing,
                onRefresh = onRefresh,
            )
            BalanceContent(state = state, providerKind = providerKind)
        }
    }
}

// MARK: - Header

@Composable
private fun BalanceHeader(
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val haptics = LocalHapticFeedback.current

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        modifier = Modifier.fillMaxWidth(),
    ) {

        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(colors.primarySoft),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.CreditCard,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(14.dp),
            )
        }

        Text(
            text = stringResource(R.string.provider_balance_title),
            style = OriveoTheme.typography.title3,
            color = colors.textPrimary,
        )

        Spacer(modifier = Modifier.weight(1f))

        RefreshButton(
            isRefreshing = isRefreshing,
            onClick = {
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                onRefresh()
            },
        )
    }
}

@Composable
private fun RefreshButton(
    isRefreshing: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val rotation = remember { Animatable(0f) }
    val refreshContentDesc = stringResource(R.string.provider_balance_refresh)

    LaunchedEffect(isRefreshing) {
        if (isRefreshing) {
            rotation.snapTo(0f)
            rotation.animateTo(
                targetValue = 360f,
                animationSpec = infiniteRepeatable(
                    animation = tween(durationMillis = 900, easing = LinearEasing),
                    repeatMode = RepeatMode.Restart,
                ),
            )
        } else {
            rotation.snapTo(0f)
        }
    }

    Box(
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .background(colors.primarySoft)
            .then(
                if (isRefreshing) Modifier.alpha(0.85f)
                else Modifier.clickable(onClick = onClick),
            )
            .semantics { contentDescription = refreshContentDesc },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Refresh,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier
                .size(14.dp)
                .graphicsLayer { rotationZ = rotation.value },
        )
    }
}

// MARK: - Content

@Composable
private fun BalanceContent(
    state: ProviderDetailViewModel.BalanceUiState,
    providerKind: ProviderKind,
) {
    when (state) {
        is ProviderDetailViewModel.BalanceUiState.Hidden -> Unit
        is ProviderDetailViewModel.BalanceUiState.Loaded -> {
            BalanceLoadedContent(balance = state.balance, providerKind = providerKind)
        }
        is ProviderDetailViewModel.BalanceUiState.Loading -> {
            BalanceSkeleton()
        }
        is ProviderDetailViewModel.BalanceUiState.Error -> {
            BalanceErrorView(isKeyInvalid = false)
        }
        is ProviderDetailViewModel.BalanceUiState.KeyInvalid -> {
            BalanceErrorView(isKeyInvalid = true)
        }
    }
}

@Composable
private fun BalanceSkeleton() {
    val colors = OriveoTheme.colors
    Column(
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            modifier = Modifier
                .width(140.dp)
                .height(36.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(colors.surfaceInset),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(colors.surfaceInset),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg)) {
            Box(
                modifier = Modifier
                    .width(80.dp)
                    .height(28.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(colors.surfaceInset),
            )
            Box(
                modifier = Modifier
                    .width(80.dp)
                    .height(28.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(colors.surfaceInset),
            )
        }
    }
}

@Composable
private fun BalanceLoadedContent(balance: ProviderBalance, providerKind: ProviderKind) {
    val colors = OriveoTheme.colors

    Column(
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        modifier = Modifier.fillMaxWidth(),
    ) {

        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = formatAmount(balance.total, balance.currency),
                style = OriveoTheme.typography.title2.copy(
                    fontSize = 32.sp,
                    fontWeight = FontWeight.Bold,
                ),
                color = colors.textPrimary,
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = balance.currency,
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textTertiary,
                modifier = Modifier.padding(bottom = 6.dp),
            )
        }

        val granted = balance.granted?.takeIf { it != 0.0 }
        val topUp = balance.topUp?.takeIf { it != 0.0 }
        val totalUsage = balance.totalUsage?.takeIf { it != 0.0 }
        val hasBreakdown = granted != null || topUp != null || totalUsage != null

        if (hasBreakdown) {
            val progress = usageProgress(balance)
            if (progress != null) {
                UsageProgressBar(progress = progress)
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
            ) {
                if (granted != null) {
                    BreakdownItem(
                        icon = Icons.Filled.AutoAwesome,
                        label = stringResource(grantedLabelRes(providerKind)),
                        value = formatAmount(granted, balance.currency),
                    )
                }
                if (topUp != null) {
                    val isOwing = providerKind == ProviderKind.Moonshot && topUp < 0
                    BreakdownItem(
                        icon = if (isOwing) Icons.Filled.WarningAmber else Icons.Filled.ArrowCircleDown,
                        label = stringResource(topUpLabelRes(providerKind)),
                        value = formatAmount(topUp, balance.currency),
                        isWarning = isOwing,
                        warningLabel = if (isOwing) stringResource(R.string.provider_balance_owing_label) else null,
                    )
                }
                if (totalUsage != null) {
                    BreakdownItem(
                        icon = Icons.Filled.ArrowCircleUp,
                        label = stringResource(R.string.provider_balance_used_label),
                        value = formatAmount(totalUsage, balance.currency),
                    )
                }
            }
        }
    }
}

@Composable
private fun UsageProgressBar(progress: Double) {
    val colors = OriveoTheme.colors
    val density = LocalDensity.current

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .height(6.dp),
    ) {
        val widthPx = with(density) { maxWidth.toPx() }
        val minFillPx = with(density) { 4.dp.toPx() }
        val fillWidthDp = with(density) {
            maxOf((widthPx * progress).toFloat(), minFillPx).toDp()
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .clip(CircleShape)
                .background(colors.primarySoft),
        )

        Box(
            modifier = Modifier
                .width(fillWidthDp)
                .fillMaxSize()
                .clip(CircleShape)
                .background(colors.primary),
        )
    }
}

@Composable
private fun BreakdownItem(
    icon: ImageVector,
    label: String,
    value: String,
    isWarning: Boolean = false,
    warningLabel: String? = null,
) {
    val colors = OriveoTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(CircleShape)
                .background(if (isWarning) colors.warningSoft else colors.surfaceInset),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (isWarning) colors.warning else colors.textSecondary,
                modifier = Modifier.size(12.dp),
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                text = label,
                style = OriveoTheme.typography.footnote,
                color = colors.textTertiary,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = value,
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                    color = if (isWarning) colors.warning else colors.textPrimary,
                )
                if (isWarning && warningLabel != null) {
                    Text(
                        text = warningLabel,
                        style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.warning,
                    )
                }
            }
        }
    }
}

@Composable
private fun BalanceErrorView(isKeyInvalid: Boolean) {
    val colors = OriveoTheme.colors
    if (isKeyInvalid) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = stringResource(R.string.provider_balance_error_key_invalid),
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.warning,
            )
            Text(
                text = stringResource(R.string.provider_balance_error_check_key),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
        }
    } else {
        Text(
            text = stringResource(R.string.provider_balance_error_fetch),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
}

// MARK: - Helpers

private fun usageProgress(b: ProviderBalance): Double? {
    val used = b.totalUsage ?: return null
    if (used <= 0) return null
    val denom = b.total + used
    if (denom <= 0) return null
    return (used / denom).coerceIn(0.0, 1.0)
}

private fun grantedLabelRes(kind: ProviderKind): Int = when (kind) {
    ProviderKind.Moonshot -> R.string.provider_balance_voucher_label
    else -> R.string.provider_balance_granted_label
}

private fun topUpLabelRes(kind: ProviderKind): Int = when (kind) {
    ProviderKind.Moonshot -> R.string.provider_balance_cash_label
    else -> R.string.provider_balance_topup_label
}

private val amountFormatter: NumberFormat = NumberFormat.getNumberInstance(Locale.US).apply {
    minimumFractionDigits = 2
    maximumFractionDigits = 2
    isGroupingUsed = true
}

private fun formatAmount(amount: Double, currency: String): String {
    val symbol = when (currency.uppercase()) {
        "USD" -> "$"
        "CNY" -> "¥"
        else -> "$currency "
    }
    val sign = if (amount < 0) "-" else ""
    val abs = kotlin.math.abs(amount)
    return symbol + sign + amountFormatter.format(abs)
}
