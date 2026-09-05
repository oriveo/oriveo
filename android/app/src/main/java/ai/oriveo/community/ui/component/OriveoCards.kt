package ai.oriveo.community.ui.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.oriveoSurface


@Composable
fun OriveoCard(
    modifier: Modifier = Modifier,
    fillColor: Color? = null,
    borderColor: Color? = null,
    shadowStyle: OriveoSurfaceStyle = OriveoSurfaceStyle.Soft,
    radius: androidx.compose.ui.unit.Dp = ai.oriveo.community.ui.theme.OriveoRadius.md,
    contentPadding: PaddingValues = PaddingValues(OriveoTheme.layout.cardPadding),
    content: @Composable () -> Unit,
) {
    val colors = OriveoTheme.colors
    
    
    val isDark = OriveoTheme.isDark

    Box(
        modifier = modifier
            .fillMaxWidth()
            .oriveoSurface(
                colors = colors,
                isDark = isDark,
                fill = fillColor ?: colors.surface,
                borderColor = borderColor ?: colors.border,
                radius = radius,
                shadowStyle = shadowStyle,
            )
            .padding(contentPadding),
    ) {
        content()
    }
}


@Composable
fun OriveoSectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    trailing: String = "",
) {
    val colors = OriveoTheme.colors

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.title3,
            color = colors.textPrimary,
        )
        if (trailing.isNotEmpty()) {
            Text(
                text = trailing,
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
    }
}


@Composable
fun OriveoEmptyState(
    icon: ImageVector,
    title: String,
    description: String,
    modifier: Modifier = Modifier,
    actionTitle: String = "",
    onAction: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(OriveoTheme.spacing.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(42.dp),
            tint = colors.textTertiary,
        )

        Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))

        Text(
            text = title,
            style = OriveoTheme.typography.title2,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )

        Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))

        Text(
            text = description,
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )

        if (actionTitle.isNotEmpty() && onAction != null) {
            Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))

            OriveoPrimaryButton(
                text = actionTitle,
                onClick = onAction,
                modifier = Modifier.widthIn(max = 220.dp),
            )
        }
    }
}
