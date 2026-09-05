package ai.oriveo.community.feature.chat.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.ui.component.CostPill
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.theme.OriveoTheme
import dev.chrisbanes.haze.HazeState

@Composable
internal fun ChatToolbar(
    skillIcon: String? = null,
    providerKind: ProviderKind?,
    relayKind: RelayKind?,
    providerName: String,
    modelName: String,
    isSendingMessage: Boolean,
    cost: Double,
    costText: String,
    showMenu: Boolean,
    onBack: () -> Unit,
    onToggleModelSwitcher: () -> Unit,
    onNewChat: () -> Unit,
    onOpenMenu: () -> Unit,
    onDismissMenu: () -> Unit,
    onExportConversation: () -> Unit,
    onDeleteConversation: () -> Unit,
    showMemoryIndicator: Boolean,
    onOpenMemoryIndicator: () -> Unit,
    showMemoryToggle: Boolean,
    memoryEnabledForConversation: Boolean,
    onToggleUseMemory: () -> Unit,
    hasMessages: Boolean,
    /** Fully transparent in the empty state so the aurora shows through; once there are messages, a gradient scrim covers the scrolling content underneath. */
    transparentChrome: Boolean,
    hazeState: HazeState,
    trueTransparentBlurEnabled: Boolean,
) {
    val colors = OriveoTheme.colors
    // Empty state stays fully transparent; once there are messages, a plain gradient
    // scrim (solid at the status bar, fading downward) lets scrolled-in messages fade
    // in softly. A plain LinearGradient with no real-time blur adds no scroll-time cost
    // and avoids a hard divider line.
    val toolbarSurfaceModifier = if (transparentChrome) {
        Modifier
    } else {
        Modifier.background(
            Brush.verticalGradient(
                colorStops = arrayOf(
                    0f to colors.background,
                    0.5f to colors.background,
                    1f to colors.background.copy(alpha = 0f),
                ),
            ),
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .then(toolbarSurfaceModifier),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = OriveoTheme.spacing.lg)
                .padding(top = OriveoTheme.spacing.md, bottom = OriveoTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        ) {
            ChatToolbarIconButton(
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(R.string.back),
                onClick = onBack,
            )

            Row(
                modifier = Modifier
                    .weight(1f)
                    .padding(start = 2.dp)
                    .clickable(onClick = onToggleModelSwitcher),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                // Skill icon, if any
                if (skillIcon != null) {
                    Text(skillIcon, fontSize = 20.sp)
                }

                providerKind?.let {
                    ProviderBadgeIcon(kind = it, size = 26.dp, relayKind = relayKind)
                }

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = modelName,
                        // 15sp Bold title -- narrowed from 17sp so long model names don't wrap to two lines
                        style = TextStyle(
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                        ),
                        color = colors.textPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (providerName.isNotEmpty()) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text(
                                text = providerName,
                                style = OriveoTheme.typography.footnote,
                                color = colors.textSecondary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            // Up/down chevron signals that the model can be switched
                            Icon(
                                imageVector = Icons.Filled.UnfoldMore,
                                contentDescription = stringResource(R.string.model_switcher),
                                modifier = Modifier.size(9.dp),
                                tint = colors.textSecondary,
                            )
                        }
                    }
                }

            }

            if (cost > 0.0) {
                CostPill(cost = cost)
            }

            if (showMemoryIndicator) {
                // Flat bare icon (no fill / no border), just a circular ripple for feedback
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .clickable(onClick = onOpenMemoryIndicator),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Psychology,
                        contentDescription = stringResource(R.string.memory_indicator),
                        modifier = Modifier.size(15.dp),
                        tint = colors.primary,
                    )
                }
            }

            Box {
                ChatToolbarIconButton(
                    icon = Icons.Filled.MoreHoriz,
                    contentDescription = stringResource(R.string.provider_list_more_actions),
                    onClick = onOpenMenu,
                )

                DropdownMenu(
                    expanded = showMenu,
                    onDismissRequest = onDismissMenu,
                ) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.new_chat)) },
                        onClick = {
                            onDismissMenu()
                            onNewChat()
                        },
                        leadingIcon = {
                            Icon(Icons.Filled.Add, contentDescription = null)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.export_conversation)) },
                        onClick = {
                            onDismissMenu()
                            onExportConversation()
                        },
                        enabled = hasMessages,
                        leadingIcon = {
                            Icon(Icons.Outlined.Share, contentDescription = null)
                        },
                    )
                    if (cost > 0.0) {
                        DropdownMenuItem(
                            text = { Text(costText) },
                            onClick = {},
                            enabled = false,
                        )
                    }
                    if (showMemoryToggle) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.memory_use_toggle)) },
                            onClick = onToggleUseMemory,
                            trailingIcon = {
                                Switch(
                                    checked = memoryEnabledForConversation,
                                    onCheckedChange = { onToggleUseMemory() },
                                )
                            },
                        )
                    }
                    if (hasMessages) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.delete_conversation)) },
                            onClick = {
                                onDismissMenu()
                                onDeleteConversation()
                            },
                            leadingIcon = {
                                Icon(Icons.Outlined.Delete, contentDescription = null)
                            },
                        )
                    }
                }
            }
        }
    }
}

/**
 * 36dp flat bare icon button -- no fill / border / shadow, just a circular ripple on press.
 *
 * The 36dp tap target plus the circular ripple keep touch feedback comfortable even
 * though the icon itself is small. Shared base for the back and overflow buttons.
 */
@Composable
private fun ChatToolbarIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    iconModifier: Modifier = Modifier,
    iconTint: Color? = null,
    enabled: Boolean = true,
) {
    val colors = OriveoTheme.colors

    Box(
        modifier = Modifier
            .size(36.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.45f),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            modifier = iconModifier.size(17.dp),
            tint = iconTint ?: colors.textPrimary,
        )
    }
}
