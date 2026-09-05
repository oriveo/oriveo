package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.feature.providers.localizedProviderEndpointLabel
import ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity


@Composable
fun ProviderDetailSettingsCard(
    provider: Provider,
    onEditEndpoint: (() -> Unit)?,
    onAdvancedSettings: (() -> Unit)?,
    onGenerationParameters: (() -> Unit)?,
    onDeleteProvider: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(16.dp)
    val showsAny = onEditEndpoint != null ||
        onAdvancedSettings != null ||
        onGenerationParameters != null ||
        onDeleteProvider != null
    if (!showsAny) return

    val hasEndpointGroup = onEditEndpoint != null
    val endpointOption = ProviderSetupCopy.resolveRegionOption(provider.kind, provider.baseUrlText)
    val isRelay = provider.kind == ProviderKind.Relay

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceElevated)
            .border(1.dp, colors.border.opacity(0.72f), shape),
    ) {
        if (onEditEndpoint != null && endpointOption != null) {
            SettingsRow(
                icon = Icons.Filled.Language,
                title = stringResource(ProviderSetupCopy.endpointTitle(provider.kind)),
                value = localizedProviderEndpointLabel(provider.kind, endpointOption),
                tint = colors.textPrimary,
                onClick = onEditEndpoint,
            )
        }

        if (hasEndpointGroup && onAdvancedSettings != null) SettingsRowDivider()

        
        
        
        
        
        if (onAdvancedSettings != null) {
            SettingsRow(
                icon = Icons.Filled.Settings,
                title = stringResource(R.string.provider_detail_connection_settings),
                value = if (isRelay) relayTransportPreviewText(provider.relayRequested) else null,
                tint = colors.textPrimary,
                onClick = onAdvancedSettings,
            )
        }

        
        
        if (onGenerationParameters != null) {
            if (hasEndpointGroup || onAdvancedSettings != null) SettingsRowDivider()
            SettingsRow(
                icon = Icons.Filled.Tune,
                title = stringResource(R.string.generation_model_behavior),
                value = null,
                tint = colors.textPrimary,
                onClick = onGenerationParameters,
            )
        }

        if ((hasEndpointGroup || onAdvancedSettings != null || onGenerationParameters != null) && onDeleteProvider != null) {
            SettingsRowDivider()
        }

        if (onDeleteProvider != null) {
            SettingsRow(
                icon = Icons.Outlined.Delete,
                title = stringResource(R.string.delete_provider),
                value = null,
                tint = colors.danger,
                onClick = onDeleteProvider,
            )
        }
    }
}

@Composable
private fun SettingsRow(
    icon: ImageVector,
    title: String,
    value: String?,
    tint: Color,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(tint.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = tint,
            )
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = tint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!value.isNullOrBlank()) {
                Text(
                    text = value,
                    style = OriveoTheme.typography.caption,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            modifier = Modifier.size(13.dp),
            tint = colors.textTertiary,
        )
    }
}

@Composable
private fun SettingsRowDivider() {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 60.dp)
            .height(0.5.dp)
            .background(colors.border.opacity(0.45f)),
    )
}


@Composable
private fun relayTransportPreviewText(requested: RelayRequestedConfig?): String? {
    val transport = requested?.transport ?: return null
    return when (transport) {
        RelayTransport.Auto -> null
        RelayTransport.OpenAIResponses -> stringResource(R.string.relay_transport_openai_responses)
        RelayTransport.OpenAIChatCompletions -> stringResource(R.string.relay_transport_openai_chat_completions)
        RelayTransport.LlamaCppNative -> stringResource(R.string.relay_transport_llamacpp_native)
        RelayTransport.AnthropicMessages -> stringResource(R.string.relay_transport_anthropic_messages)
        RelayTransport.GeminiGenerateContent -> stringResource(R.string.relay_transport_gemini_generate_content)
    }
}
