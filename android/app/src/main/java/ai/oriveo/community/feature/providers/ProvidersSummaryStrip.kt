package ai.oriveo.community.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.IncompleteCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun ProvidersSummaryStrip(
    providerCount: Int,
    availableModelCount: Int,
    connectedCount: Int,
    syncingCount: Int,
    issueCount: Int,
    modifier: Modifier = Modifier,
) {
    val badge = computeStatusBadge(
        providerCount = providerCount,
        connectedCount = connectedCount,
        syncingCount = syncingCount,
        issueCount = issueCount,
    )

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp),
    ) {
        val narrow = maxWidth < 340.dp
        if (narrow) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                MetricsLine(providerCount = providerCount, availableModelCount = availableModelCount)
                if (badge != null) {
                    StatusBadge(badge = badge)
                }
            }
        } else {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                MetricsLine(providerCount = providerCount, availableModelCount = availableModelCount)
                if (badge != null) {
                    StatusBadge(badge = badge)
                }
            }
        }
    }
}

@Composable
private fun MetricsLine(providerCount: Int, availableModelCount: Int) {
    val colors = OriveoTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = countText(
                format = stringResource(R.string.providers_summary_count, providerCount),
                count = providerCount,
                primary = colors.textPrimary,
                secondary = colors.textSecondary,
            ),
            style = compactTextStyle(
                TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, lineHeight = 16.sp),
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        DotDivider()
        Text(
            text = countText(
                format = stringResource(R.string.models_count, availableModelCount),
                count = availableModelCount,
                primary = colors.textPrimary,
                secondary = colors.textSecondary,
            ),
            style = compactTextStyle(
                TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, lineHeight = 16.sp),
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private fun countText(
    format: String,
    count: Int,
    primary: Color,
    secondary: Color,
) = buildAnnotatedString {
    val digits = count.toString()
    val idx = format.indexOf(digits)
    if (idx < 0) {
        withStyle(SpanStyle(color = secondary)) { append(format) }
        return@buildAnnotatedString
    }
    withStyle(SpanStyle(color = secondary)) { append(format.substring(0, idx)) }
    withStyle(
        SpanStyle(
            color = primary,
            fontWeight = FontWeight.SemiBold,
            fontSize = 14.sp,
        ),
    ) { append(digits) }
    withStyle(SpanStyle(color = secondary)) { append(format.substring(idx + digits.length)) }
}

@Composable
private fun DotDivider() {
    Box(
        modifier = Modifier
            .padding(horizontal = 2.dp)
            .size(3.dp)
            .clip(CircleShape)
            .background(OriveoTheme.colors.textTertiary.copy(alpha = 0.5f)),
    )
}

private data class StatusBadgeData(
    val icon: ImageVector,
    val value: String?,
    val label: String,
    val tone: BadgeTone,
)

private enum class BadgeTone { Warning, Primary, Success }

@Composable
private fun StatusBadge(badge: StatusBadgeData) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val toneColor = when (badge.tone) {
        BadgeTone.Warning -> colors.warning
        BadgeTone.Primary -> colors.primary
        BadgeTone.Success -> colors.success
    }
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(toneColor.copy(alpha = if (isDark) 0.14f else 0.10f))
            .border(
                width = 0.6.dp,
                color = toneColor.copy(alpha = if (isDark) 0.24f else 0.18f),
                shape = CircleShape,
            )
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = badge.icon,
            contentDescription = null,
            modifier = Modifier.size(10.dp),
            tint = toneColor.copy(alpha = 0.92f),
        )
        if (badge.value != null) {
            Text(
                text = badge.value,
                style = compactTextStyle(
                    TextStyle(
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        lineHeight = 13.sp,
                        fontFeatureSettings = "tnum",
                    ),
                ),
                color = colors.textPrimary,
                maxLines = 1,
            )
        }
        Text(
            text = badge.label,
            style = compactTextStyle(
                TextStyle(fontSize = 11.5.sp, fontWeight = FontWeight.Medium, lineHeight = 13.sp),
            ),
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun computeStatusBadge(
    providerCount: Int,
    connectedCount: Int,
    syncingCount: Int,
    issueCount: Int,
): StatusBadgeData? {
    if (issueCount > 0) {
        return StatusBadgeData(
            icon = Icons.Filled.Warning,
            value = issueCount.toString(),
            label = stringResource(R.string.status_issue),
            tone = BadgeTone.Warning,
        )
    }
    if (syncingCount > 0) {
        return StatusBadgeData(
            icon = Icons.Outlined.Sync,
            value = syncingCount.toString(),
            label = stringResource(R.string.status_syncing),
            tone = BadgeTone.Primary,
        )
    }
    if (providerCount > 0 && connectedCount == providerCount) {
        return StatusBadgeData(
            icon = Icons.Filled.CheckCircle,
            value = null,
            label = stringResource(R.string.providers_all_synced),
            tone = BadgeTone.Success,
        )
    }
    if (providerCount > 0) {
        return StatusBadgeData(
            icon = Icons.Filled.IncompleteCircle,
            value = "$connectedCount/$providerCount",
            label = stringResource(R.string.status_connected),
            tone = BadgeTone.Success,
        )
    }
    return null
}

private fun compactTextStyle(base: TextStyle): TextStyle =
    base.copy(
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.Both,
        ),
    )
