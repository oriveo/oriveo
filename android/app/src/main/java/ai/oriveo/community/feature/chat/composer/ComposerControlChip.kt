package ai.oriveo.community.feature.chat.composer

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

@Composable
internal fun ComposerControlChip(
    title: String,
    icon: ImageVector,
    accent: ComposerCapabilityAccent,
    emphasized: Boolean,
    disabled: Boolean,
    badgeText: String?,
    accessory: ComposerControlChipAccessory,
    capabilityIcons: List<ImageVector> = emptyList(),
    accessibilityState: String? = null,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDarkTheme = OriveoTheme.isDark
    val chipShape = RoundedCornerShape(999.dp)
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val chipScale by animateFloatAsState(if (pressed) 0.975f else 1f, label = "composerChipScale")

    
    
    val emphasisScale by animateFloatAsState(
        targetValue = if (emphasized) 1.02f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium),
        label = "composerChipEmphasis",
    )

    val chipFill = if (emphasized) {
        accent.softFill.opacity(if (isDarkTheme) 0.68f else 0.8f)
    } else {
        composerDynamicColor(light = 0xF9FAFD, dark = 0x121A2A, lightAlpha = 0.58f, darkAlpha = 0.58f)
    }
    val chipShadowColor = if (emphasized) accent.shadow.copy(alpha = 0.08f) else Color.Transparent
    val iconColor = if (emphasized) accent.tint else colors.textTertiary
    val titleColor = if (emphasized) colors.textPrimary else colors.textTertiary

    Row(
        modifier = Modifier
            .graphicsLayer {
                scaleX = chipScale
                scaleY = chipScale
                alpha = if (disabled) 0.52f else if (pressed) 0.94f else 1f
            }
            .shadow(
                elevation = if (emphasized) 7.dp else 0.dp,
                shape = chipShape,
                ambientColor = chipShadowColor,
                spotColor = chipShadowColor,
            )
            .clip(chipShape)
            .background(color = chipFill, shape = chipShape)
            .then(
                if (emphasized) {
                    Modifier.drawWithCache {
                        val cr = CornerRadius(size.height / 2f, size.height / 2f)
                        val tintColor = accent.softFill.opacity(if (isDarkTheme) 0.08f else 0.12f)
                        val chipTopHighlight = if (isDarkTheme) colors.cardHighlight.opacity(0.375f)
                            else Color.White.copy(alpha = 0.12f)
                        val topGradient = Brush.verticalGradient(
                            colors = listOf(
                                chipTopHighlight,
                                Color.Transparent,
                            ),
                            endY = size.height * 0.3f,
                        )
                        onDrawWithContent {
                            drawContent()
                            drawRoundRect(color = tintColor, cornerRadius = cr)
                            drawRoundRect(brush = topGradient, cornerRadius = cr)
                        }
                    }
                } else {
                    Modifier
                },
            )
            .clickable(
                enabled = !disabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .then(
                if (accessibilityState.isNullOrBlank()) Modifier else Modifier.semantics {
                    stateDescription = accessibilityState
                },
            )
            .heightIn(min = 34.dp)
            .widthIn(min = 44.dp)
            .padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(17.dp)
                .graphicsLayer {
                    scaleX = emphasisScale
                    scaleY = emphasisScale
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(12.5.dp),
                tint = iconColor,
            )
        }

        Text(
            text = title,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = titleColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        if (emphasized && badgeText == null) {
            if (capabilityIcons.isEmpty()) {
                ComposerEmphasisOrb(accent)
            } else {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(3.5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    capabilityIcons.forEach { capabilityIcon ->
                        Icon(
                            imageVector = capabilityIcon,
                            contentDescription = null,
                            modifier = Modifier.size(10.5.dp),
                            tint = accent.tint,
                        )
                    }
                }
            }
        }

        if (badgeText != null) {
            Text(
                text = badgeText,
                style = OriveoTheme.typography.footnote.copy(fontSize = 10.25.sp, fontWeight = FontWeight.Medium),
                color = if (emphasized) accent.tint.copy(alpha = 0.86f)
                    else colors.textTertiary.copy(alpha = 0.74f),
                maxLines = 1,
            )
        }

        when (accessory) {
            ComposerControlChipAccessory.None -> Unit
            ComposerControlChipAccessory.Chevron -> {
                Icon(
                    imageVector = Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    modifier = Modifier.size(11.dp),
                    tint = colors.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun ComposerEmphasisOrb(accent: ComposerCapabilityAccent) {
    Box(
        modifier = Modifier
            .size(12.dp)
            .background(accent.softFill, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(5.5.dp)
                .shadow(
                    elevation = 4.dp,
                    shape = CircleShape,
                    ambientColor = accent.shadow.copy(alpha = 0.22f),
                    spotColor = accent.shadow.copy(alpha = 0.22f),
                )
                .background(accent.iconEnd, CircleShape),
        )
    }
}
