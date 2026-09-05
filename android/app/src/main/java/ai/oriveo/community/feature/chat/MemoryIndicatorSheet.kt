package ai.oriveo.community.feature.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.oriveoSurface

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryIndicatorSheet(
    memoryText: String,
    onDismiss: () -> Unit,
    onViewEdit: () -> Unit,
    onDisableForConversation: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val preview = memoryPopoverPreviewText(memoryText)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        dragHandle = { OriveoSheetDragHandle() },
        containerColor = colors.surface,
        contentColor = colors.textPrimary,
        scrimColor = colors.overlay,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.layout.screenH)
                .padding(bottom = OriveoTheme.spacing.xxl),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .oriveoSurface(
                        colors = colors,
                        isDark = isDark,
                        fill = colors.surfaceChrome,
                        borderColor = colors.borderStrong,
                        radius = 18.dp,
                        shadowStyle = OriveoSurfaceStyle.Soft,
                    )
                    .padding(OriveoTheme.spacing.lg),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            ) {
                Box(
                    modifier = Modifier
                        .size(46.dp)
                        .clip(CircleShape)
                        .background(
                            brush = Brush.linearGradient(
                                colors = listOf(colors.primary, colors.primaryPressed),
                            ),
                        )
                        .border(1.dp, colors.hairline, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Psychology,
                        contentDescription = null,
                        tint = colors.textInverse,
                        modifier = Modifier.size(20.dp),
                    )
                }

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = stringResource(R.string.memory_indicator_title),
                        style = OriveoTheme.typography.title2,
                        color = colors.textPrimary,
                    )

                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(colors.primarySoft)
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                    ) {
                        Text(
                            text = stringResource(R.string.memory_title),
                            style = OriveoTheme.typography.footnote,
                            color = colors.primary,
                        )
                    }
                }

                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(colors.surfaceInset)
                        .border(1.dp, colors.border, CircleShape)
                        .clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = stringResource(R.string.close),
                        tint = colors.textTertiary,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }

            MemoryPreviewCard(previewText = preview)

            Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                MemoryActionButton(
                    title = stringResource(R.string.memory_indicator_view_edit),
                    icon = {
                        Icon(
                            imageVector = Icons.Outlined.Edit,
                            contentDescription = null,
                            tint = colors.textInverse,
                            modifier = Modifier.size(15.dp),
                        )
                    },
                    tone = MemoryActionTone.Primary,
                    onClick = onViewEdit,
                )

                onDisableForConversation?.let { disable ->
                    MemoryActionButton(
                        title = stringResource(R.string.memory_indicator_disable),
                        icon = {
                            Icon(
                                imageVector = Icons.Outlined.VisibilityOff,
                                contentDescription = null,
                                tint = colors.danger,
                                modifier = Modifier.size(15.dp),
                            )
                        },
                        tone = MemoryActionTone.Danger,
                        onClick = disable,
                    )
                }
            }
        }
    }
}

internal fun memoryPopoverPreviewText(memoryText: String): String {
    val trimmedText = memoryText.trim()
    if (trimmedText.isEmpty()) return ""

    return buildString {
        append(trimmedText.takeGraphemes(300))
        if (trimmedText.graphemeCount() > 300) {
            append("...")
        }
    }
}

@Composable
private fun MemoryPreviewCard(previewText: String) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .oriveoSurface(
                colors = colors,
                isDark = isDark,
                fill = colors.surfaceInset,
                borderColor = colors.border,
                radius = 18.dp,
                shadowStyle = OriveoSurfaceStyle.None,
            )
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        colors.primarySoft.copy(alpha = if (isDark) 0.28f else 0.5f),
                        Color.Transparent,
                    ),
                ),
                shape = RoundedCornerShape(18.dp),
            )
            .padding(OriveoTheme.spacing.lg),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = stringResource(R.string.memory_title),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )

            Icon(
                imageVector = Icons.Outlined.Psychology,
                contentDescription = null,
                tint = colors.primary.copy(alpha = 0.72f),
                modifier = Modifier.size(16.dp),
            )
        }

        Text(
            text = previewText,
            style = OriveoTheme.typography.body,
            color = colors.textPrimary,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 150.dp)
                .verticalScroll(rememberScrollState()),
        )
    }
}

private enum class MemoryActionTone {
    Primary,
    Danger,
}

@Composable
private fun MemoryActionButton(
    title: String,
    icon: @Composable () -> Unit,
    tone: MemoryActionTone,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape: Shape = RoundedCornerShape(16.dp)

    val backgroundModifier = when (tone) {
        MemoryActionTone.Primary -> Modifier.background(
            brush = Brush.linearGradient(
                colors = listOf(colors.primary, colors.primaryPressed),
            ),
            shape = shape,
        )
        MemoryActionTone.Danger -> Modifier.background(
            color = colors.dangerSoft,
            shape = shape,
        )
    }

    val borderColor = when (tone) {
        MemoryActionTone.Primary -> colors.hairline
        MemoryActionTone.Danger -> colors.danger.copy(alpha = 0.2f)
    }

    val contentColor = when (tone) {
        MemoryActionTone.Primary -> colors.textInverse
        MemoryActionTone.Danger -> colors.danger
    }

    val iconBackground = when (tone) {
        MemoryActionTone.Primary -> Color.White.copy(alpha = 0.16f)
        MemoryActionTone.Danger -> colors.danger.copy(alpha = 0.12f)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .then(backgroundModifier)
            .border(1.dp, borderColor, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(iconBackground),
            contentAlignment = Alignment.Center,
        ) {
            icon()
        }

        Text(
            text = title,
            style = OriveoTheme.typography.title3,
            color = contentColor,
            modifier = Modifier.weight(1f),
        )

        Icon(
            imageVector = Icons.AutoMirrored.Filled.ArrowForward,
            contentDescription = null,
            tint = contentColor.copy(alpha = 0.76f),
            modifier = Modifier.size(16.dp),
        )
    }
}
