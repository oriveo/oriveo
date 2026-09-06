package ai.oriveo.community.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun ProvidersSectionTitle(
    modifier: Modifier = Modifier,
    leading: @Composable () -> Unit,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        leading()
        trailing?.invoke()
    }
}

@Composable
fun ProvidersClusterTitleLabel() {
    val colors = OriveoTheme.colors
    Text(
        text = stringResource(R.string.providers_title),
        style = compactTextStyle(
            OriveoTheme.typography.title1.copy(
                fontSize = 32.sp,
                lineHeight = 38.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.6).sp,
            ),
        ),
        color = colors.textPrimary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
fun CostSectionTitleLabel() {
    SectionTitleLabelWithIcon(
        icon = Icons.AutoMirrored.Outlined.TrendingUp,
        text = stringResource(R.string.costs_title),
    )
}

@Composable
private fun SectionTitleLabelWithIcon(icon: ImageVector, text: String) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val boxShape = RoundedCornerShape(9.dp)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(boxShape)
                .background(
                    color = colors.primary.copy(alpha = if (isDark) 0.16f else 0.10f),
                    shape = boxShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = colors.primary.copy(alpha = 0.92f),
            )
        }

        Text(
            text = text,
            style = compactTextStyle(
                OriveoTheme.typography.title1.copy(
                    fontSize = 22.sp,
                    lineHeight = 26.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = (-0.44).sp,
                ),
            ),
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
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
