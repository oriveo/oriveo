package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.Icon
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * E-697: the realtime model awaits the voice catalog but the catalog failed to load.
 * Sits above the composer with a retry; the button is disabled while a retry is in flight.
 */
@Composable
internal fun VoiceCatalogUnavailableRow(
    retrying: Boolean,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    // Mirrors iOS realtimeCatalogRetryRowView: warning-tinted surface with a hairline border, corner 10.
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(10.dp)
    val fill = colors.warning.copy(alpha = if (isDark) 0.14f else 0.08f)
    val stroke = colors.warning.copy(alpha = if (isDark) 0.28f else 0.20f)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.xs)
            .background(fill, shape)
            .border(1.dp, stroke, shape)
            .padding(start = OriveoTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Outlined.ErrorOutline,
            contentDescription = null,
            tint = colors.warning,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(OriveoTheme.spacing.sm))
        Text(
            text = stringResource(R.string.voice_realtime_catalog_unavailable),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
        TextButton(
            onClick = onRetry,
            enabled = !retrying,
        ) {
            Text(
                text = stringResource(R.string.retry),
                fontWeight = FontWeight.SemiBold,
                color = if (retrying) colors.textSecondary else colors.primary,
            )
        }
    }
}
