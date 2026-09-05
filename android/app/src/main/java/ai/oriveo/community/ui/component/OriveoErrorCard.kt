package ai.oriveo.community.ui.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Warning
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
fun OriveoErrorCard(
    error: OriveoError,
    modifier: Modifier = Modifier,
    onAction: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    var showDetail by remember { mutableStateOf(false) }

    val (foreground, bg) = when (error.severity) {
        OriveoErrorSeverity.Warning -> colors.warning to colors.warningSoft
        OriveoErrorSeverity.Critical -> colors.danger to colors.dangerSoft
    }
    val borderColor = foreground.copy(alpha = 0.28f)
    val shape = RoundedCornerShape(OriveoRadius.md)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(bg)
            .border(OriveoBorderWidth.standard, borderColor, shape)
            .padding(OriveoTheme.spacing.lg),
    ) {
        // Header: icon + title
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = when (error.severity) {
                    OriveoErrorSeverity.Warning -> Icons.Outlined.Warning
                    OriveoErrorSeverity.Critical -> Icons.Outlined.Close
                },
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = foreground,
            )
            Spacer(modifier = Modifier.width(OriveoTheme.spacing.sm))
            Text(
                text = error.title,
                style = OriveoTheme.typography.title3,
                color = foreground,
            )
        }

        // Message
        if (error.message.isNotEmpty()) {
            Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
            Text(
                text = error.message,
                style = OriveoTheme.typography.caption,
                color = colors.textPrimary,
            )
        }

        // Expandable detail
        if (error.detail.isNotEmpty()) {
            Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
            OriveoTextButton(
                text = if (showDetail) {
                    stringResource(R.string.hide_details)
                } else {
                    stringResource(R.string.technical_details)
                },
                onClick = { showDetail = !showDetail },
                color = colors.textTertiary,
            )

            AnimatedVisibility(
                visible = showDetail,
                enter = expandVertically(),
                exit = shrinkVertically(),
            ) {
                Text(
                    text = error.detail,
                    style = OriveoTheme.typography.code,
                    color = colors.textSecondary,
                    modifier = Modifier
                        .padding(top = OriveoTheme.spacing.sm)
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(OriveoRadius.sm))
                        .background(colors.surfaceInset)
                        .padding(OriveoTheme.spacing.md),
                )
            }
        }

        // Action button
        if (error.actionTitle.isNotEmpty() && onAction != null) {
            Spacer(modifier = Modifier.height(OriveoTheme.spacing.md))
            OriveoPrimaryButton(
                text = error.actionTitle,
                onClick = onAction,
            )
        }
    }
}
