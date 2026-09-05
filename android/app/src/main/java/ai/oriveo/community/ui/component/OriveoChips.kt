package ai.oriveo.community.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.ProviderBadgeColors


enum class StatusTone {
    Primary, Success, Warning, Danger, Neutral;

    @Composable
    fun foreground(): Color = when (this) {
        Primary -> OriveoTheme.colors.primary
        Success -> OriveoTheme.colors.success
        Warning -> OriveoTheme.colors.warning
        Danger -> OriveoTheme.colors.danger
        Neutral -> OriveoTheme.colors.textSecondary
    }

    @Composable
    fun background(): Color = when (this) {
        Primary -> OriveoTheme.colors.primarySoft
        Success -> OriveoTheme.colors.successSoft
        Warning -> OriveoTheme.colors.warningSoft
        Danger -> OriveoTheme.colors.dangerSoft
        Neutral -> OriveoTheme.colors.surface
    }
}


@Composable
fun StatusPill(
    text: String,
    tone: StatusTone,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
    micro: Boolean = false,
) {
    val fg = tone.foreground()
    val bg = tone.background()

    Text(
        text = text,
        style = if (micro) {
            OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium)
        } else if (compact) {
            OriveoTheme.typography.caption.copy(fontWeight = FontWeight.Medium)
        } else {
            OriveoTheme.typography.footnote
        },
        color = fg,
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .border(OriveoBorderWidth.standard, fg.copy(alpha = 0.18f), CircleShape)
            .padding(
                horizontal = if (micro) 6.dp else if (compact) 8.dp else OriveoTheme.spacing.sm,
                vertical = if (micro) 2.5.dp else if (compact) 4.dp else OriveoTheme.spacing.xs,
            ),
    )
}

@Composable
fun ModelRowActionPill(
    text: String,
    modifier: Modifier = Modifier,
    tone: StatusTone = StatusTone.Primary,
) {
    val fg = tone.foreground()
    val bg = tone.background()

    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .border(OriveoBorderWidth.standard, fg.copy(alpha = 0.18f), CircleShape)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Filled.Add,
            contentDescription = null,
            modifier = Modifier.size(11.dp),
            tint = fg,
        )
        Text(
            text = text,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = fg,
        )
    }
}


@Composable
fun ProviderModelChip(
    kind: ProviderKind,
    modelName: String,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val brand = ProviderBadgeColors.forProvider(kind)

    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(brand.background)
            .padding(horizontal = 7.dp, vertical = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProviderBadgeIcon(kind = kind, size = 14.dp)

        Text(
            text = modelName,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}


@Composable
fun CapabilityChip(
    text: String,
    modifier: Modifier = Modifier,
    emphasized: Boolean = false,
) {
    val colors = OriveoTheme.colors
    val fg = if (emphasized) colors.primary else colors.textSecondary
    val bg = if (emphasized) colors.primarySoft else colors.surfaceChrome
    val borderAlpha = if (emphasized) 0.35f else 0.18f

    Text(
        text = text,
        style = OriveoTheme.typography.footnote,
        color = fg,
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .border(OriveoBorderWidth.standard, fg.copy(alpha = borderAlpha), CircleShape)
            .padding(horizontal = OriveoTheme.spacing.sm, vertical = OriveoTheme.spacing.xs),
    )
}


@Composable
fun ModelCapabilityBadge(
    capability: ModelCapability,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val colors = OriveoTheme.colors
    val palette = capabilityBadgeColors(capability, colors)

    val icon = capabilityIcon(capability)
    val horizontalPadding: Dp = if (compact) 7.dp else 10.dp
    val verticalPadding: Dp = if (compact) 3.dp else 5.dp
    val iconSize: Dp = if (compact) 11.dp else 13.dp
    val itemSpacing: Dp = if (compact) 4.dp else 6.dp

    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(palette.background)
            .border(OriveoBorderWidth.standard, palette.border, CircleShape)
            .padding(horizontal = horizontalPadding, vertical = verticalPadding),
        horizontalArrangement = Arrangement.spacedBy(itemSpacing),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(iconSize),
            tint = palette.foreground,
        )
        Text(
            text = stringResource(capability.titleResId),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),
            color = palette.foreground,
            maxLines = 1,
            softWrap = false,
            overflow = TextOverflow.Clip,
        )
    }
}

@Composable
fun HeroModelCapabilityBadge(
    capability: ModelCapability,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val palette = capabilityBadgeColors(capability, colors)
    val shellShape = RoundedCornerShape(14.dp)
    val shellBackground = lerp(colors.surfaceElevated, colors.surface, 0.52f)
    val shellBorder = colors.borderStrong.opacity(if (OriveoTheme.isDark) 0.58f else 0.72f)
    val shellHighlight = Color.White.copy(alpha = if (OriveoTheme.isDark) 0.05f else 0.52f)
    val accentBar = lerp(
        palette.foreground.copy(alpha = if (OriveoTheme.isDark) 0.88f else 0.74f),
        palette.foreground.copy(alpha = if (OriveoTheme.isDark) 0.32f else 0.22f),
        0.45f,
    )
    val iconBackground = lerp(
        palette.foreground.copy(alpha = if (OriveoTheme.isDark) 0.18f else 0.14f),
        palette.foreground.copy(alpha = if (OriveoTheme.isDark) 0.08f else 0.05f),
        0.45f,
    )
    val iconRing = palette.foreground.copy(alpha = if (OriveoTheme.isDark) 0.34f else 0.18f)

    Row(
        modifier = modifier
            .shadow(
                elevation = if (OriveoTheme.isDark) 12.dp else 6.dp,
                shape = shellShape,
                ambientColor = colors.shadow.opacity(if (OriveoTheme.isDark) 0.34f else 0.10f),
                spotColor = colors.shadow.opacity(if (OriveoTheme.isDark) 0.34f else 0.10f),
            )
            .clip(shellShape)
            .background(shellBackground)
            .border(OriveoBorderWidth.standard, shellBorder, shellShape)
            .border(OriveoBorderWidth.fine, shellHighlight, shellShape)
            .padding(start = 9.dp, end = 11.dp, top = 7.dp, bottom = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(width = 3.dp, height = 16.dp)
                .clip(CircleShape)
                .background(accentBar),
        )
        Box(
            modifier = Modifier
                .size(19.dp)
                .clip(CircleShape)
                .background(iconBackground)
                .border(0.8.dp, iconRing, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = capabilityIcon(capability),
                contentDescription = null,
                modifier = Modifier.size(10.dp),
                tint = palette.foreground,
            )
        }
        Text(
            text = stringResource(capability.titleResId),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            maxLines = 1,
            softWrap = false,
            overflow = TextOverflow.Clip,
        )
    }
}

private data class CapabilityBadgeColors(
    val foreground: Color,
    val background: Color,
    val border: Color,
)

private fun capabilityBadgeColors(
    capability: ModelCapability,
    colors: OriveoColors,
): CapabilityBadgeColors = when (capability) {
    ModelCapability.Reasoning -> CapabilityBadgeColors(colors.capReasoning, colors.capReasoningBg, colors.capReasoningBorder)
    ModelCapability.Text -> CapabilityBadgeColors(colors.capText, colors.capTextBg, colors.capTextBorder)
    ModelCapability.Image -> CapabilityBadgeColors(colors.capImage, colors.capImageBg, colors.capImageBorder)
    ModelCapability.Video -> CapabilityBadgeColors(colors.capImage, colors.capImageBg, colors.capImageBorder)
    ModelCapability.File -> CapabilityBadgeColors(colors.capFile, colors.capFileBg, colors.capFileBorder)
    ModelCapability.Web -> CapabilityBadgeColors(colors.capWeb, colors.capWebBg, colors.capWebBorder)
    ModelCapability.ImageGen -> CapabilityBadgeColors(colors.capImageGen, colors.capImageGenBg, colors.capImageGenBorder)
    ModelCapability.ToolCall -> CapabilityBadgeColors(colors.capWeb, colors.capWebBg, colors.capWebBorder)
    ModelCapability.NativePdf -> CapabilityBadgeColors(colors.capFile, colors.capFileBg, colors.capFileBorder)
    ModelCapability.Unknown -> CapabilityBadgeColors(colors.capText, colors.capTextBg, colors.capTextBorder)
}

internal fun capabilityIcon(capability: ModelCapability): ImageVector = when (capability) {
    ModelCapability.Reasoning -> Icons.Outlined.Psychology
    ModelCapability.Text -> Icons.AutoMirrored.Outlined.Notes
    ModelCapability.Image -> Icons.Outlined.Image
    ModelCapability.Video -> Icons.Outlined.Videocam
    ModelCapability.File -> Icons.Outlined.Description
    ModelCapability.Web -> Icons.Outlined.Language
    ModelCapability.ImageGen -> Icons.Outlined.Brush
    ModelCapability.ToolCall -> Icons.Outlined.Build
    ModelCapability.NativePdf -> Icons.Outlined.Description
    ModelCapability.Unknown -> Icons.AutoMirrored.Outlined.Notes
}
