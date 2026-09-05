package ai.oriveo.community.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
fun ModelCard(
    displayName: String,
    vendorName: String? = null,
    groupName: String? = null,
    capabilities: List<ModelCapability> = emptyList(),
    pricingStatus: String,
    priceLabel: String? = null,
    isRecommended: Boolean = false,
    isEnabled: Boolean = false,
    isDefault: Boolean = false,
    isManualRetained: Boolean = false,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.surface)
            .let { m -> if (onClick != null) m.clickable { onClick() } else m }
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = displayName,
                style = OriveoTheme.typography.body,
                color = colors.textPrimary,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            if (isEnabled) {
                ModelBadge(text = "ENABLED", tint = colors.textSecondary)
            }
            if (isRecommended && !isEnabled) {
                ModelBadge(text = "★", tint = colors.primary)
            }
        }

        
        val subtitle = vendorName?.takeIf { it.isNotBlank() } ?: groupName?.takeIf { it.isNotBlank() }
        if (subtitle != null) {
            Text(
                text = subtitle,
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
        }

        
        if (capabilities.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                capabilities.forEach { cap ->
                    CapabilityBadge(cap)
                }
            }
        }

        
        when (pricingStatus) {
            "priced" -> priceLabel?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = OriveoTheme.typography.caption, color = colors.textSecondary)
            }
            "free" -> Text("Free", style = OriveoTheme.typography.caption, color = colors.primary)
            "unknown" -> Text("Pricing unknown", style = OriveoTheme.typography.caption, color = colors.textSecondary)
        }

        if (isManualRetained) {
            Text(
                text = "Custom / Unknown",
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun ModelBadge(text: String, tint: androidx.compose.ui.graphics.Color) {
    Text(
        text = text,
        style = OriveoTheme.typography.caption,
        color = tint,
        fontWeight = FontWeight.Bold,
    )
}

@Composable
private fun CapabilityBadge(capability: ModelCapability) {
    val label = when (capability) {
        ModelCapability.Reasoning -> "Reasoning"
        ModelCapability.Text -> "Text"
        ModelCapability.Image -> "Vision"
        ModelCapability.Video -> "Video"
        ModelCapability.File -> "File"
        ModelCapability.Web -> "Web"
        ModelCapability.ImageGen -> "Image"
        ModelCapability.ToolCall -> "Tools"
        ModelCapability.NativePdf -> "PDF"
        ModelCapability.Unknown -> ""
    }
    Text(
        text = label,
        style = OriveoTheme.typography.caption,
        color = OriveoTheme.colors.textSecondary,
    )
}
