package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun RelaySecurityModeControl(
    endpoint: String,
    selectedMode: RelayConnectionSecurityMode,
    hasCredentialMaterial: Boolean,
    enabled: Boolean,
    onModeSelected: (RelayConnectionSecurityMode, RelaySecurityModePolicy.Assessment, Boolean) -> Unit,
) {
    var assessment by remember(endpoint) {
        mutableStateOf(
            RelaySecurityModePolicy.assess(endpoint, emptyList()),
        )
    }
    var showPicker by remember { mutableStateOf(false) }
    var pendingDowngrade by remember { mutableStateOf<RelayConnectionSecurityMode?>(null) }
    var ignoredSuggestionFor by remember(endpoint) { mutableStateOf(false) }

    LaunchedEffect(endpoint) {
        assessment = RelaySecurityModePolicy.assessResolving(endpoint)
    }

    RelaySecurityModeSummaryRow(
        mode = selectedMode,
        enabled = enabled,
        onChange = { showPicker = true },
    )

    val suggested = assessment.suggestedMode
        ?.takeIf { selectedMode == RelayConnectionSecurityMode.RemoteHttps && !ignoredSuggestionFor }
    if (suggested != null) {
        Spacer(modifier = Modifier.size(OriveoTheme.spacing.sm))
        RelaySecurityModeSuggestionCard(
            mode = suggested,
            onKeepHttps = { ignoredSuggestionFor = true },
            onAccept = { pendingDowngrade = suggested },
        )
    }

    if (showPicker) {
        RelaySecurityModePickerDialog(
            selectedMode = selectedMode,
            assessment = assessment,
            onDismiss = { showPicker = false },
            onSelect = { mode ->
                showPicker = false
                if (mode == RelayConnectionSecurityMode.RemoteHttps) {
                    onModeSelected(mode, assessment, false)
                } else {
                    pendingDowngrade = mode
                }
            },
        )
    }

    pendingDowngrade?.let { pending ->
        AlertDialog(
            onDismissRequest = { pendingDowngrade = null },
            title = { Text(stringResource(modeTitleRes(pending))) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                    Text(stringResource(modeDescriptionRes(pending)))
                    if (hasCredentialMaterial) {
                        Text(
                            text = stringResource(R.string.relay_security_mode_clear_credentials_warning),
                            color = OriveoTheme.colors.warning,
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onModeSelected(pending, assessment, true)
                        pendingDowngrade = null
                    },
                ) {
                    Text(
                        stringResource(
                            if (pending == RelayConnectionSecurityMode.PrivateVpn) {
                                R.string.relay_security_mode_use_private_vpn
                            } else {
                                R.string.relay_security_mode_use_local_http
                            },
                        ),
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDowngrade = null }) {
                    Text(stringResource(R.string.relay_security_mode_keep_https))
                }
            },
        )
    }
}

@Composable
private fun RelaySecurityModeSummaryRow(
    mode: RelayConnectionSecurityMode,
    enabled: Boolean,
    onChange: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onChange)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Icon(
            imageVector = Icons.Filled.Lock,
            contentDescription = null,
            tint = colors.info,
            modifier = Modifier.size(18.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = stringResource(R.string.relay_security_mode_label),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
                maxLines = 1,
            )
            Text(
                text = stringResource(modeTitleRes(mode)),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = stringResource(modeDescriptionRes(mode)),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            text = stringResource(R.string.relay_type_row_change),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = if (enabled) colors.primary else colors.textTertiary,
            maxLines = 1,
        )
        Icon(
            imageVector = Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = colors.textTertiary,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun RelaySecurityModeSuggestionCard(
    mode: RelayConnectionSecurityMode,
    onKeepHttps: () -> Unit,
    onAccept: () -> Unit,
) {
    OriveoCard(
        fillColor = OriveoTheme.colors.primarySoft,
        borderColor = OriveoTheme.colors.primary.copy(alpha = 0.16f),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Text(
                text = stringResource(
                    if (mode == RelayConnectionSecurityMode.PrivateVpn) {
                        R.string.relay_security_mode_suggest_vpn
                    } else {
                        R.string.relay_security_mode_suggest_local
                    },
                ),
                style = OriveoTheme.typography.caption,
                color = OriveoTheme.colors.textSecondary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                OriveoPrimaryButton(
                    text = stringResource(R.string.relay_security_mode_keep_https),
                    onClick = onKeepHttps,
                    modifier = Modifier.weight(1f),
                )
                OriveoSecondaryButton(
                    text = stringResource(
                        if (mode == RelayConnectionSecurityMode.PrivateVpn) {
                            R.string.relay_security_mode_use_private_vpn
                        } else {
                            R.string.relay_security_mode_use_local_http
                        },
                    ),
                    onClick = onAccept,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun RelaySecurityModePickerDialog(
    selectedMode: RelayConnectionSecurityMode,
    assessment: RelaySecurityModePolicy.Assessment,
    onDismiss: () -> Unit,
    onSelect: (RelayConnectionSecurityMode) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.relay_security_mode_label)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                visibleModes.forEach { mode ->
                    val option = when (mode) {
                        RelayConnectionSecurityMode.RemoteHttps -> RelaySecurityModePolicy.Option(true, "encrypted_remote")
                        RelayConnectionSecurityMode.LocalHttp -> assessment.localHttp
                        RelayConnectionSecurityMode.PrivateVpn -> assessment.privateVpn
                        RelayConnectionSecurityMode.TofuHttps -> error("TOFU is not a picker option")
                    }
                    RelaySecurityModeOptionRow(
                        mode = mode,
                        selected = selectedMode == mode,
                        enabled = option.enabled,
                        disabledReason = option.reason,
                        onClick = { onSelect(mode) },
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
private fun RelaySecurityModeOptionRow(
    mode: RelayConnectionSecurityMode,
    selected: Boolean,
    enabled: Boolean,
    disabledReason: String,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .background(
                color = if (selected) colors.primarySoft else colors.surfaceInset,
                shape = RoundedCornerShape(OriveoTheme.radius.md),
            )
            .padding(vertical = 8.dp, horizontal = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        RadioButton(selected = selected, onClick = onClick, enabled = enabled)
        Column(modifier = Modifier.weight(1f).padding(top = 3.dp)) {
            Text(
                text = stringResource(modeTitleRes(mode)),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = if (enabled) colors.textPrimary else colors.textTertiary,
            )
            Text(
                text = stringResource(
                    if (enabled) modeDescriptionRes(mode) else disabledReasonRes(disabledReason),
                ),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
    }
}

private val visibleModes = listOf(
    RelayConnectionSecurityMode.RemoteHttps,
    RelayConnectionSecurityMode.LocalHttp,
    RelayConnectionSecurityMode.PrivateVpn,
)

private fun modeTitleRes(mode: RelayConnectionSecurityMode): Int = when (mode) {
    RelayConnectionSecurityMode.RemoteHttps -> R.string.relay_security_mode_remote_https
    RelayConnectionSecurityMode.TofuHttps -> R.string.relay_security_mode_paired_https
    RelayConnectionSecurityMode.LocalHttp -> R.string.relay_security_mode_local_http
    RelayConnectionSecurityMode.PrivateVpn -> R.string.relay_security_mode_private_vpn
}

private fun modeDescriptionRes(mode: RelayConnectionSecurityMode): Int = when (mode) {
    RelayConnectionSecurityMode.RemoteHttps -> R.string.relay_security_mode_remote_https_description
    RelayConnectionSecurityMode.TofuHttps -> R.string.relay_security_mode_paired_https_description
    RelayConnectionSecurityMode.LocalHttp -> R.string.relay_security_mode_local_http_description
    RelayConnectionSecurityMode.PrivateVpn -> R.string.relay_security_mode_private_vpn_description
}

private fun disabledReasonRes(reason: String): Int = when (reason) {
    "public_address", "mixed_resolution" -> R.string.relay_security_mode_option_public_disabled
    "encrypted_endpoint" -> R.string.relay_security_mode_https_required
    else -> R.string.relay_security_mode_option_unknown_disabled
}
