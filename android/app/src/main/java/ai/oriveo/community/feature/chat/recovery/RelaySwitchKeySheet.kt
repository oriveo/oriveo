package ai.oriveo.community.feature.chat.recovery

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.theme.OriveoTheme

/** One key in the panel: name or mask + mask. */
data class RelaySwitchKeyOption(val keyId: String, val title: String, val maskedSecret: String)

/**
 * Chat "Switch to another key": derived only from the persisted `relayDeniedKeyID` and alternates, without adding fields to the message.
 * Condition = a failed assistant message + the model (connection + model id) is still enabled + the current key has no access + another key lists it.
 */
object RelaySwitchKey {
    fun options(provider: Provider?, message: ChatMessage): List<RelaySwitchKeyOption> {
        if (provider == null || provider.kind != ProviderKind.Relay) return emptyList()
        if (message.role != ChatRole.Assistant || message.state != ChatMessageState.Failed) return emptyList()
        val modelID = message.modelID ?: return emptyList()
        if (provider.models.none { it.id == modelID }) return emptyList()
        val state = RelayKeyBinding.modelState(provider, modelID)
        if (!state.deniedOnCurrentKey || state.alternateKeyIDs.isEmpty()) return emptyList()
        val rows = RelayKeyBinding.rows(provider).associateBy { it.id }
        return state.alternateKeyIDs.mapNotNull { id ->
            rows[id]?.let { row -> RelaySwitchKeyOption(id, row.name?.takeIf(String::isNotBlank) ?: row.maskedSecret, row.maskedSecret) }
        }
    }
}

/** Selecting a key -> the caller rebinds; the panel closes right away and does not resend automatically (the user taps the existing retry). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RelaySwitchKeySheet(
    modelName: String,
    options: List<RelaySwitchKeyOption>,
    onSelect: (RelaySwitchKeyOption) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(bottom = OriveoTheme.spacing.xl),
        ) {
            Text(
                text = stringResource(R.string.relay_chat_switch_key_title, modelName),
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
                modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
            )
            Text(
                text = stringResource(R.string.relay_chat_switch_key_hint),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg).padding(bottom = OriveoTheme.spacing.sm),
            )
            options.forEach { option ->
                ListItem(
                    headlineContent = { Text(option.title) },
                    supportingContent = option.maskedSecret.takeIf { it != option.title }?.let { masked -> { Text(masked) } },
                    leadingContent = {
                        androidx.compose.material3.Icon(
                            painter = painterResource(R.drawable.ph_key),
                            contentDescription = null,
                            tint = colors.textSecondary,
                        )
                    },
                    modifier = Modifier.clickable {
                        onSelect(option)
                        onDismiss()
                    },
                )
            }
        }
    }
}
