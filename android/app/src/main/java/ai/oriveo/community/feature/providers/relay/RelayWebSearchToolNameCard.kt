package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayWebSearchToolName
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
internal fun RelayWebSearchToolNameCard(
    selected: RelayWebSearchToolName,
    onSelect: (RelayWebSearchToolName) -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoTheme.radius.md)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surface)
            .border(OriveoBorderWidth.standard, colors.border, shape)
            .padding(OriveoTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Text(
            text = stringResource(R.string.relay_advanced_web_search_tool_name).uppercase(),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs)) {
            RelayWebSearchToolName.entries.forEach { option ->
                val isSelected = option == selected
                val labelText = when (option) {
                    RelayWebSearchToolName.WebSearch -> "web_search"
                    RelayWebSearchToolName.WebSearchPreview -> "web_search_preview"
                    RelayWebSearchToolName.Disabled -> stringResource(R.string.relay_web_search_tool_disabled)
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(OriveoTheme.radius.sm))
                        .background(if (isSelected) colors.primarySoft else colors.surfaceInset)
                        .border(
                            width = if (isSelected) 1.dp else OriveoBorderWidth.standard,
                            color = if (isSelected) colors.primary.copy(alpha = 0.4f) else colors.border,
                            shape = RoundedCornerShape(OriveoTheme.radius.sm),
                        )
                        .clickable { onSelect(option) }
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = labelText,
                        style = OriveoTheme.typography.caption.copy(
                            fontFamily = if (option != RelayWebSearchToolName.Disabled) FontFamily.Monospace else FontFamily.Default,
                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        ),
                        color = if (isSelected) colors.primary else colors.textSecondary,
                        textAlign = TextAlign.Center,
                        maxLines = 1,
                    )
                }
            }
        }
        val hintRes = when (selected) {
            RelayWebSearchToolName.WebSearch -> R.string.relay_web_search_tool_hint_default
            RelayWebSearchToolName.WebSearchPreview -> R.string.relay_web_search_tool_hint_legacy
            RelayWebSearchToolName.Disabled -> R.string.relay_web_search_tool_hint_disabled
        }
        Text(
            text = stringResource(hintRes),
            style = OriveoTheme.typography.caption,
            color = if (selected == RelayWebSearchToolName.Disabled) colors.warning else colors.textTertiary,
        )
    }
}

