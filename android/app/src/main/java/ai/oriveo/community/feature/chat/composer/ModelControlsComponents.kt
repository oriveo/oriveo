package ai.oriveo.community.feature.chat.composer

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoTheme


// MARK: - Surface


@Composable
internal fun Modifier.modelControlSurface(cornerRadius: Int = 20): Modifier {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(cornerRadius.dp)
    return this
        .shadow(
            elevation = if (isDark) 10.dp else 14.dp,
            shape = shape,
            ambientColor = Color.Black.copy(alpha = if (isDark) 0.28f else 0.045f),
            spotColor = Color.Black.copy(alpha = if (isDark) 0.28f else 0.045f),
        )
        .background(color = if (isDark) colors.surfaceElevated else colors.surface, shape = shape)
}

// MARK: - Status badge


enum class ModelControlStatusTone { Manual, Unavailable }


@Composable
internal fun ModelControlStatusBadge(tone: ModelControlStatusTone, text: String) {
    val colors = OriveoTheme.colors
    
    val fill = when (tone) {
        ModelControlStatusTone.Manual -> colors.warning
        ModelControlStatusTone.Unavailable -> colors.textSecondary
    }
    val label = when (tone) {
        
        
        ModelControlStatusTone.Manual -> colors.warningText
        
        
        
        ModelControlStatusTone.Unavailable -> colors.textPrimary
    }
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.SemiBold,
        color = label,
        maxLines = 1,
        
        
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .clip(RoundedCornerShape(OriveoRadius.full))
            .background(fill.copy(alpha = modelControlBadgeCapsuleAlpha(OriveoTheme.isDark)))
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .semantics(mergeDescendants = true) { },
    )
}


internal fun modelControlBadgeCapsuleAlpha(isDark: Boolean): Float = if (isDark) 0.20f else 0.12f

// MARK: - Card


@Composable
internal fun ModelControlCard(
    icon: ImageVector,
    title: String,
    badge: Pair<ModelControlStatusTone, String>?,
    toggle: Boolean?,
    onToggle: ((Boolean) -> Unit)?,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .modelControlSurface()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                
                
                tint = colors.primaryTextSafe,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(10.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.width(8.dp))
            
            
            if (toggle != null && onToggle != null) {
                Switch(
                    checked = toggle,
                    onCheckedChange = onToggle,
                    colors = SwitchDefaults.colors(checkedTrackColor = colors.primaryTextSafe),
                    modifier = Modifier
                        .heightIn(min = 44.dp)
                        .semantics { contentDescription = title },
                )
            } else if (badge != null) {
                ModelControlStatusBadge(badge.first, badge.second)
            }
        }
        content()
    }
}

// MARK: - Intent pills


@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ModelControlIntentPicker(
    options: List<ModelControlIntentOption>,
    selection: String,
    onSelect: (String) -> Unit,
) {
    if (options.isEmpty()) return
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val haptic = LocalHapticFeedback.current
    val selectedLabel = stringResource(R.string.selected)
    val unselectedLabel = stringResource(R.string.model_control_not_selected)
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEach { option ->
            val selected = option.id == selection
            val label = stringResource(option.labelRes)
            Box(
                modifier = Modifier
                    
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(OriveoRadius.full))
                    
                    
                    
                    .clickable {
                        if (selected) return@clickable
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        onSelect(option.id)
                    }
                    .semantics {
                        role = Role.RadioButton
                        contentDescription = label
                        this.selected = selected
                        stateDescription = if (selected) selectedLabel else unselectedLabel
                    },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        
                        
                        .defaultMinSize(minWidth = 56.dp, minHeight = 36.dp)
                        .clip(RoundedCornerShape(OriveoRadius.full))
                        .background(
                            if (selected) colors.primaryTextSafe
                            else colors.textPrimary.copy(alpha = modelControlUnselectedPillAlpha(isDark)),
                        )
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = label,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                        
                        
                        color = if (selected) {
                            colors.textInverse
                        } else {
                            modelControlUnselectedPillLabel(colors, isDark)
                        },
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}


internal fun modelControlUnselectedPillAlpha(isDark: Boolean): Float = if (isDark) 0.10f else 0.06f


internal fun modelControlUnselectedPillLabel(colors: OriveoColors, isDark: Boolean): Color =
    if (isDark) colors.textSecondary else Color(0xFF52525B)

// MARK: - Status row


@Composable
internal fun ModelControlStatusRow(text: String, onClick: (() -> Unit)?) {
    val colors = OriveoTheme.colors
    val base = Modifier
        .fillMaxWidth()
        .heightIn(min = 44.dp)
    Row(
        modifier = if (onClick != null) {
            base
                .clickable(onClick = onClick)
                .semantics(mergeDescendants = true) { role = Role.Button }
        } else {
            base.semantics(mergeDescendants = true) { }
        },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
        if (onClick != null) {
            Spacer(Modifier.width(8.dp))
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

// MARK: - Notes & inline actions


@Composable
internal fun ModelControlNote(
    text: String,
    icon: ImageVector? = null,
    
    
    
    tone: Color = OriveoTheme.colors.textSecondary,
) {
    Row(verticalAlignment = Alignment.Top) {
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tone,
                modifier = Modifier
                    .padding(top = 2.dp, end = 6.dp)
                    .size(13.dp),
            )
        }
        Text(
            text = text,
            
            
            style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
            color = tone,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
internal fun ModelControlNote(
    @StringRes textRes: Int,
    icon: ImageVector? = null,
    tone: Color = OriveoTheme.colors.textSecondary,
) {
    ModelControlNote(text = stringResource(textRes), icon = icon, tone = tone)
}


@Composable
internal fun ModelControlInlineAction(
    title: String,
    icon: ImageVector,
    tint: Color = OriveoTheme.colors.primaryTextSafe,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) { role = Role.Button },
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(0.5.dp)
                .background(colors.textPrimary.copy(alpha = 0.06f)),
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .padding(top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = tint, modifier = Modifier.size(15.dp))
            Spacer(Modifier.width(7.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = tint,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}


@Composable
internal fun ModelControlNavigationRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    trailingText: String?,
    badge: Pair<ModelControlStatusTone, String>?,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .modelControlSurface()
            .clip(RoundedCornerShape(20.dp))
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) { role = Role.Button }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.primaryTextSafe,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            
            if (subtitle.isNotEmpty()) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
                    color = colors.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        if (badge != null) {
            ModelControlStatusBadge(badge.first, badge.second)
        } else if (!trailingText.isNullOrEmpty()) {
            Text(
                text = trailingText,
                style = MaterialTheme.typography.bodyMedium,
                color = colors.textSecondary,
                maxLines = 1,
            )
        }
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier
                .padding(start = 4.dp)
                .size(16.dp),
        )
    }
}


@Composable
internal fun ModelControlHairline(leadingInset: Int = 16) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = leadingInset.dp)
            .height(0.5.dp)
            .background(OriveoTheme.colors.textPrimary.copy(alpha = 0.08f)),
    )
}


@Composable
internal fun ModelControlListRow(title: String, status: String) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .padding(horizontal = 16.dp)
            .semantics(mergeDescendants = true) {
                contentDescription = title
                stateDescription = status
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.Medium,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = status,
            style = MaterialTheme.typography.bodyMedium,
            color = colors.textSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}


@Composable
internal fun ModelControlsCloseBar(onClose: () -> Unit) {
    val colors = OriveoTheme.colors
    Column(modifier = Modifier.fillMaxWidth().background(colors.surfaceChrome)) {
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.border))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 50.dp)
                .clickable(onClick = onClose)
                .semantics(mergeDescendants = true) { role = Role.Button }
                .padding(horizontal = 16.dp, vertical = 10.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = stringResource(R.string.close),
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
            )
        }
    }
}


@Composable
internal fun ModelControlScopeUpgradeRow(isConfirmed: Boolean, onPromote: () -> Unit) {
    val colors = OriveoTheme.colors
    Column(modifier = Modifier.fillMaxWidth().background(colors.surfaceChrome)) {
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.border))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (isConfirmed) {
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = colors.primaryTextSafe,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = stringResource(R.string.model_control_model_default_saved),
                    style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                )
            } else {
                Text(
                    text = stringResource(R.string.model_control_applied_to_conversation),
                    style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                Box(
                    modifier = Modifier
                        .heightIn(min = 44.dp)
                        
                        
                        
                        .widthIn(max = 160.dp)
                        .clickable(onClick = onPromote)
                        .semantics(mergeDescendants = true) { role = Role.Button },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = stringResource(R.string.model_control_set_as_model_default),
                        style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
                        fontWeight = FontWeight.SemiBold,
                        color = colors.primaryTextSafe,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
