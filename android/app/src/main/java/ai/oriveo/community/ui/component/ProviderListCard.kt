package ai.oriveo.community.ui.component

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderEffectiveStatusKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.effectiveStatusKind
import ai.oriveo.community.core.model.resolveProviderLogoKind
import ai.oriveo.community.core.provider.BALANCE_CAPABLE_KINDS
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.ProviderBadgeColors
import ai.oriveo.community.ui.util.formatRelativeTime
import java.text.NumberFormat
import java.util.Locale

/**
 * One row of the provider list: brand rail, logo, name and sub row, trailing amount, chevron.
 *
 * - a 3.5dp brand-colour gradient rail, 38dp tall with a 2dp radius, so each provider gets its own
 *   visual anchor down the left edge of an otherwise uniform list
 * - a 38dp logo
 * - the name at 16.5sp SemiBold (letterSpacing -0.2) with an inline status dot
 * - a sub row carrying the model count, a 2.5dp separator dot, and the relative sync time
 * - a trailing amount at 12.5sp SemiBold, dimmed when it is zero, plus an 11dp chevron
 *
 * The trailing figure carries only a short label rather than a full caption; its position in the row
 * supplies the rest of the meaning.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ProviderListCard(
    provider: Provider,
    availableModelCount: Int,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    monthlyEstimatedCost: Double = 0.0,
    providerBalance: ProviderBalance? = null,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    // Keep the remember keys down to the fields that actually feed logo resolution. provider.status
    // and lastCheckedAt churn on every tick of a running sync, and including them would re-resolve
    // the logo each time for nothing. A non-Relay provider depends on its kind alone; only Relay has
    // to look at displayName / baseUrl / models, because that is what the logo heuristic matches on.
    val resolvedLogoKind = remember(
        provider.kind,
        provider.relayKind,
        provider.displayName,
        provider.baseUrlText,
        provider.models,
    ) { resolveProviderLogoKind(provider) }
    val brandColor = if (resolvedLogoKind == ProviderKind.Relay) {
        colors.primary
    } else {
        ProviderBadgeColors.usageBreakdown(resolvedLogoKind)
    }
    // Read the effective status so a provider whose key is missing on this device shows as needs-key
    // (amber, "Needs API key") rather than as plain disconnected, matching the provider detail screen.
    val effective = provider.effectiveStatusKind
    val statusColor = providerStatusColor(effective, colors)
    val statusIsPulsing = effective == ProviderEffectiveStatusKind.Syncing
    val statusText = providerStatusLabel(effective)
    val showsInlineStatus = !effective.isHealthy

    val neverText = stringResource(R.string.never)
    val syncText = remember(provider.lastCheckedAt, neverText) {
        provider.lastCheckedAt?.let(::formatRelativeTime) ?: neverText
    }
    val isAggregatedMismatch = provider.kind.isAggregatedProvider &&
        provider.enabledModelCount != availableModelCount
    val modelsText = if (isAggregatedMismatch) {
        stringResource(R.string.models_added_count, provider.enabledModelCount)
    } else {
        stringResource(R.string.models_count, availableModelCount)
    }
    val monthlyCostText = remember(monthlyEstimatedCost) {
        rememberMonthlyCostText(monthlyEstimatedCost)
    }
    val isMonthlyCostZero = monthlyEstimatedCost <= CostFormatter.COST_EPSILON
    val trailingAmount = remember(
        provider.kind,
        monthlyCostText,
        isMonthlyCostZero,
        providerBalance,
    ) {
        providerListTrailingAmount(
            providerKind = provider.kind,
            monthlyCostText = monthlyCostText,
            isMonthlyCostZero = isMonthlyCostZero,
            providerBalance = providerBalance,
        )
    }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 1) Leading brand rail, with 14dp of margin before it and 16dp after.
        Spacer(Modifier.requiredWidth(14.dp))
        BrandBar(brandColor = brandColor, isDark = isDark)
        Spacer(Modifier.requiredWidth(16.dp))

        // 2) 38dp logo followed by a 13dp gap.
        ProviderBadgeIcon(
            kind = resolvedLogoKind,
            size = 38.dp,
            relayKind = provider.relayKind.takeIf {
                provider.kind == ProviderKind.Relay && resolvedLogoKind == ProviderKind.Relay
            },
        )
        Spacer(Modifier.requiredWidth(13.dp))

        // 3) Centre column: name row over sub row.
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            NameRow(
                name = provider.displayName,
                statusColor = statusColor,
                statusText = statusText,
                statusIsPulsing = statusIsPulsing,
                showStatus = showsInlineStatus,
                textPrimary = colors.textPrimary,
            )
            SubRow(
                modelsText = modelsText,
                syncText = syncText,
                colors = colors,
            )
        }

        // 4) Trailing amount and chevron, both fixed width so they stay pinned to the right edge.
        Spacer(Modifier.requiredWidth(8.dp))
        TrailingRegion(
            amount = trailingAmount,
            colors = colors,
        )
        Spacer(Modifier.requiredWidth(14.dp))
    }
}

@Composable
private fun BrandBar(brandColor: Color, isDark: Boolean) {
    // Every card in the list owns a BrandBar, and the whole column recomposes whenever model
    // metadata refreshes or a monthly cost changes. Brush.verticalGradient allocates on every call,
    // so the brush is cached against brandColor and isDark instead of being rebuilt each pass.
    val brush = remember(brandColor, isDark) {
        Brush.verticalGradient(
            colors = listOf(
                brandColor.copy(alpha = if (isDark) 1.0f else 0.92f),
                brandColor.copy(alpha = if (isDark) 0.72f else 0.62f),
            ),
        )
    }
    Box(
        modifier = Modifier
            .requiredWidth(3.5.dp)
            .requiredHeight(38.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(brush),
    )
}

@Composable
private fun NameRow(
    name: String,
    statusColor: Color,
    statusText: String,
    statusIsPulsing: Boolean,
    showStatus: Boolean,
    textPrimary: Color,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = name,
            modifier = Modifier.weight(1f, fill = false),
            style = ProviderNameTextStyle,
            color = textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        if (showStatus) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                OriveoStatusDot(color = statusColor, size = 6.dp, pulsing = statusIsPulsing)
                Text(
                    text = statusText,
                    style = ProviderStatusTextStyle,
                    color = statusColor,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun SubRow(
    modelsText: String,
    syncText: String,
    colors: OriveoColors,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = modelsText,
            style = ProviderSubTextStyle,
            color = colors.textTertiary,
            maxLines = 1,
        )

        SubDot(colors)

        Text(
            text = syncText,
            style = ProviderSubTextStyle,
            color = colors.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SubDot(colors: OriveoColors) {
    Box(
        modifier = Modifier
            .size(2.5.dp)
            .background(colors.textTertiary.copy(alpha = 0.45f), CircleShape),
    )
}

@Composable
private fun TrailingRegion(
    amount: ProviderListTrailingAmount,
    colors: OriveoColors,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // The 10.5sp label and the 12.5sp amount differ in size and, once a CJK locale pulls in a
        // fallback face, in font metrics too. Bottom alignment would settle each Text on its own
        // descent and lift whichever has the deeper one, so the two baselines visibly disagree.
        // Baseline alignment is what makes them read as a single line.
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = stringResource(amount.labelRes),
                style = ProviderAmountLabelTextStyle,
                color = colors.textTertiary,
                maxLines = 1,
                modifier = Modifier.alignByBaseline(),
            )
            Text(
                text = amount.text,
                style = ProviderCostTextStyle,
                color = if (amount.isZero) colors.textTertiary else colors.textPrimary,
                maxLines = 1,
                modifier = Modifier
                    .alignByBaseline()
                    .then(if (amount.isZero) Modifier.alpha(0.85f) else Modifier),
            )
        }

        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            modifier = Modifier.size(11.dp),
            tint = colors.textTertiary.copy(alpha = 0.55f),
        )
    }
}

internal data class ProviderListTrailingAmount(
    val labelRes: Int,
    val text: String,
    val isZero: Boolean,
)

/**
 * The per-provider spend figure is always shown. The money it reports is paid by the user directly
 * to the upstream vendor, and the number itself is derived on device by summing the estimated cost
 * recorded on each message, so it is a local reading of the user's own traffic.
 *
 * Providers whose API exposes a prepaid balance show that instead, since for them the balance is the
 * number the user actually watches.
 */
internal fun providerListTrailingAmount(
    providerKind: ProviderKind,
    monthlyCostText: String,
    isMonthlyCostZero: Boolean,
    providerBalance: ProviderBalance?,
): ProviderListTrailingAmount = when {
    providerKind in BALANCE_CAPABLE_KINDS -> ProviderListTrailingAmount(
        labelRes = R.string.provider_list_balance_label,
        text = providerBalance?.let(::formatProviderBalanceAmount) ?: "--",
        isZero = providerBalance?.total == 0.0,
    )
    else -> ProviderListTrailingAmount(
        labelRes = R.string.provider_list_usage_label,
        text = monthlyCostText,
        isZero = isMonthlyCostZero,
    )
}

internal fun formatProviderBalanceAmount(
    balance: ProviderBalance,
    locale: Locale = Locale.US,
): String {
    val formatter = NumberFormat.getNumberInstance(locale).apply {
        minimumFractionDigits = 2
        maximumFractionDigits = 2
        isGroupingUsed = true
    }
    val symbol = if (balance.currency.uppercase() == "CNY") "¥" else "$"
    val sign = if (balance.total < 0) "-" else ""
    return "$sign$symbol${formatter.format(kotlin.math.abs(balance.total))}"
}

private fun providerStatusColor(
    effective: ProviderEffectiveStatusKind,
    colors: OriveoColors,
): Color = when (effective) {
    ProviderEffectiveStatusKind.Connected -> colors.success
    ProviderEffectiveStatusKind.Syncing -> colors.primary
    ProviderEffectiveStatusKind.Issue, ProviderEffectiveStatusKind.NeedsKey -> colors.warning
}

@Composable
private fun providerStatusLabel(effective: ProviderEffectiveStatusKind): String = when (effective) {
    ProviderEffectiveStatusKind.Connected -> stringResource(R.string.status_connected)
    ProviderEffectiveStatusKind.Syncing -> stringResource(R.string.status_syncing)
    ProviderEffectiveStatusKind.Issue -> stringResource(R.string.status_issue)
    ProviderEffectiveStatusKind.NeedsKey -> stringResource(R.string.needs_api_key)
}

private fun compactTextStyle(base: TextStyle): TextStyle =
    base.copy(
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.Both,
        ),
    )

// Every card draws three Text nodes and the whole column recomposes on a metadata refresh or a
// monthly-cost change. compactTextStyle() takes its base style by value, so building these inline
// would allocate two TextStyle objects per Text on every pass; hoisting the fixed styles to
// file-level singletons turns that into a one-time cost.
private val ProviderNameTextStyle: TextStyle = compactTextStyle(
    TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.5.sp,
        lineHeight = 20.sp,
        letterSpacing = (-0.2).sp,
    ),
)
private val ProviderStatusTextStyle: TextStyle = compactTextStyle(
    TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 11.sp,
        lineHeight = 13.sp,
    ),
)
private val ProviderSubTextStyle: TextStyle = compactTextStyle(
    TextStyle(fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 14.sp),
)
// Roboto's digits are squarer and keep their stroke ends uncurved, so at a given point size they
// read heavier and larger than a rounded face would. The amount is stepped down one notch to
// compensate rather than carrying a size that only looked right in another typeface.
private val ProviderCostTextStyle: TextStyle = compactTextStyle(
    TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 12.5.sp,
        lineHeight = 15.sp,
        letterSpacing = (-0.2).sp,
        fontFeatureSettings = "tnum",
    ),
)
private val ProviderAmountLabelTextStyle: TextStyle = compactTextStyle(
    TextStyle(fontWeight = FontWeight.Medium, fontSize = 10.5.sp, lineHeight = 13.sp),
)

private fun rememberMonthlyCostText(monthlyEstimatedCost: Double): String {
    val formatted = CostFormatter.format(monthlyEstimatedCost)
    return if (formatted.isBlank()) "$0" else compactCurrencyText(formatted)
}

private fun compactCurrencyText(text: String): String {
    val separatorIndex = text.lastIndexOf('.')
    if (separatorIndex == -1 || separatorIndex == text.lastIndex) return text
    val prefix = text.substring(0, separatorIndex + 1)
    var suffix = text.substring(separatorIndex + 1)
    while (suffix.length > 2 && suffix.endsWith("0")) suffix = suffix.dropLast(1)
    while (suffix.length > 1 && suffix.endsWith("0")) suffix = suffix.dropLast(1)
    return prefix + suffix
}

fun shouldShowProviderListErrorCopy(
    @Suppress("UNUSED_PARAMETER") provider: Provider,
): Boolean = false

/** Maps a persisted English error key onto its localized message in the current language. */
@Composable
fun localizedProviderError(key: String): String = when (key) {
    "The API key could not be validated. Check the value or generate a new key." ->
        stringResource(R.string.error_invalid_api_key_message)
    "The provider is temporarily rate limiting this request. Please wait a moment and try again." ->
        stringResource(R.string.error_rate_limited_message)
    "The provider returned an empty model catalog, so we could not finish setup." ->
        stringResource(R.string.error_no_models_message)
    "The provider returned no assistant content for this message." ->
        stringResource(R.string.error_empty_response_message)
    "The selected provider configuration is incomplete, so the request could not be sent." ->
        stringResource(R.string.error_config_message)
    "The request did not complete successfully. Please check your network and try again." ->
        stringResource(R.string.error_network_message)
    "The provider returned an error for this request. Please retry or switch models." ->
        stringResource(R.string.error_upstream_message)
    "We couldn't verify the connection. You can retry from the provider details." ->
        stringResource(R.string.provider_connection_unverified)
    else -> key
}
