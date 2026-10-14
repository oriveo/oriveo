package ai.oriveo.community.feature.providers.local

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.LocalEngineChannels
import ai.oriveo.community.core.provider.LocalEngineConnectionFailure
import ai.oriveo.community.core.provider.LocalEngineContract
import ai.oriveo.community.core.provider.LocalEngineDiscoverySession
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.core.provider.wireName
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.CustomLLMSetupCoordinator
import ai.oriveo.community.feature.providers.SetupBoardSlot
import ai.oriveo.community.feature.providers.SetupDetectionCard
import ai.oriveo.community.feature.providers.relay.RelayMenuRow
import ai.oriveo.community.feature.providers.relay.RelayQuickField
import ai.oriveo.community.feature.providers.relay.RelayRowDivider
import ai.oriveo.community.feature.providers.relay.RelayRowGroup
import ai.oriveo.community.feature.providers.relay.RelaySecurityModeControl
import ai.oriveo.community.feature.providers.relay.SetupBoardHero
import ai.oriveo.community.feature.providers.relay.SetupCardTitleRow
import ai.oriveo.community.feature.providers.relay.SetupDetectingCard
import ai.oriveo.community.feature.providers.relay.SetupDot
import ai.oriveo.community.feature.providers.relay.SetupResultCard
import ai.oriveo.community.feature.providers.relay.localizedLabel
import ai.oriveo.community.feature.providers.relay.setupSchemeChip
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.launch
import org.koin.androidx.compose.koinViewModel

/** UI-only state for the optional LAN discovery affordance. */
private sealed interface LocalDiscoveryUiState {
    data object Idle : LocalDiscoveryUiState
    data object Scanning : LocalDiscoveryUiState
}

/**
 * Local compute fields inside the single Custom LLM shell.
 *
 * The first-connect path deliberately contains only the information required to connect; runtime
 * tuning and prompt-cache controls must not block this primary task. The outer shell owns the
 * sticky primary action.
 */
@Composable
fun LocalComputeSetupFields(
    onCompleted: (String) -> Unit,
    coordinator: CustomLLMSetupCoordinator,
    viewModel: LocalComputeSetupViewModel = koinViewModel(),
) {
    viewModel.attachCoordinator(coordinator)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val discovery = remember(context) { LocalEngineDiscoverySession(context) }
    var discoveryState by remember { mutableStateOf<LocalDiscoveryUiState>(LocalDiscoveryUiState.Idle) }

    DisposableEffect(discovery) {
        onDispose {
            discovery.cancel()
            viewModel.cancelConnection()
            viewModel.clearCompletionForMethodChange()
        }
    }
    LaunchedEffect(viewModel.completedProvider?.id) {
        viewModel.completedProvider?.id?.let { providerID ->
            if (coordinator.canNavigate(CustomLLMConnectionMethod.Local)) onCompleted(providerID)
        }
    }

    fun stopDiscovery(next: LocalDiscoveryUiState) {
        discovery.cancel()
        discoveryState = next
    }

    fun startDiscovery() {
        if (discoveryState == LocalDiscoveryUiState.Scanning) {
            stopDiscovery(LocalDiscoveryUiState.Idle)
            return
        }
        discoveryState = LocalDiscoveryUiState.Scanning
        viewModel.clearDiscoveredEndpoints()
        val knownHost = runCatching { java.net.URI(viewModel.endpoint).host }.getOrNull()
            ?.takeUnless { it == "localhost" || it == "127.0.0.1" }
        discovery.start(
            scope = scope,
            knownHosts = listOfNotNull(knownHost),
            onResult = { result ->
                scope.launch {
                    if (discoveryState != LocalDiscoveryUiState.Scanning) return@launch
                    // Results go into the chip row under the address slot; the first one still fills in the address, and scanning continues until the discovery window ends.
                    if (viewModel.networkChips.isEmpty()) viewModel.updateEndpoint(result.endpoint)
                    viewModel.addDiscoveredEndpoint(result.endpoint)
                }
            },
            onComplete = {
                scope.launch {
                    if (discoveryState == LocalDiscoveryUiState.Scanning) {
                        stopDiscovery(LocalDiscoveryUiState.Idle)
                    }
                }
            },
        )
    }

    val board = viewModel.board
    val colors = OriveoTheme.colors
    val scanning = discoveryState == LocalDiscoveryUiState.Scanning

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xl),
    ) {
        SetupBoardHero(
            icon = painterResource(R.drawable.ph_plug),
            label = stringResource(board.heroLabel),
            title = stringResource(board.heroTitle),
            subtitle = stringResource(board.heroSubtitle),
            tint = colors.success,
        )

        board.slots.forEach { slot ->
            when (slot) {
                SetupBoardSlot.Address -> Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                    RelayQuickField(
                        label = stringResource(R.string.relay_detail_engine_address),
                        value = viewModel.endpoint,
                        onValueChange = {
                            stopDiscovery(LocalDiscoveryUiState.Idle)
                            viewModel.updateEndpoint(it)
                        },
                        placeholder = LocalEngineContract.templates.getValue(viewModel.engine).defaultEndpoint,
                        icon = painterResource(R.drawable.ph_hard_drives),
                        keyboardType = KeyboardType.Uri,
                        selectionRange = viewModel.endpointHighlightRange,
                        schemeChip = setupSchemeChip(
                            viewModel.endpoint,
                            cleartext = viewModel.securityMode != RelayConnectionSecurityMode.RemoteHttps &&
                                viewModel.securityMode != RelayConnectionSecurityMode.TofuHttps,
                        ),
                        enabled = !viewModel.isConnecting,
                        trailing = {
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(OriveoTheme.radius.inset))
                                    .background(colors.surfaceInset)
                                    .clickable(enabled = !viewModel.isConnecting, onClick = ::startDiscovery)
                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(painterResource(R.drawable.ph_scan), contentDescription = null, tint = colors.success, modifier = Modifier.size(16.dp))
                                Text(
                                    text = stringResource(if (scanning) R.string.cancel else R.string.search),
                                    style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                                    color = colors.textPrimary,
                                )
                            }
                        },
                    )
                    if (board.networkChips.isNotEmpty()) {
                        LocalNetworkChips(
                            chips = board.networkChips,
                            selected = viewModel.endpoint,
                            onSelect = {
                                stopDiscovery(LocalDiscoveryUiState.Idle)
                                viewModel.updateEndpoint(it)
                            },
                        )
                    }
                    RelaySecurityModeControl(
                        endpoint = viewModel.endpoint,
                        selectedMode = viewModel.securityMode,
                        hasCredentialMaterial = viewModel.hasCredentialMaterial,
                        enabled = !viewModel.isConnecting,
                        onModeSelected = { mode, assessment, confirmed ->
                            viewModel.setSecurityMode(mode, assessment, confirmed)
                        },
                    )
                    if (viewModel.endpoint.contains("localhost", ignoreCase = true) || "127.0.0.1" in viewModel.endpoint) {
                        Text(
                            text = stringResource(R.string.local_compute_localhost_phone),
                            style = OriveoTheme.typography.footnote,
                            color = colors.warning,
                        )
                    }
                    if (SetupBoardSlot.ApiKey !in board.slots) {
                        Text(
                            text = stringResource(R.string.local_compute_no_credentials),
                            style = OriveoTheme.typography.footnote,
                            color = colors.textSecondary,
                        )
                    }
                }
                SetupBoardSlot.ApiKey -> RelayQuickField(
                    label = stringResource(R.string.api_key),
                    value = viewModel.apiKey,
                    onValueChange = viewModel::updateApiKey,
                    placeholder = stringResource(R.string.relay_api_key_placeholder),
                    icon = painterResource(R.drawable.ph_key),
                    secure = true,
                    enabled = !viewModel.isConnecting,
                )
                // "Add another key" belongs only to step 1 of the relay setup.
                SetupBoardSlot.AddKey -> Unit
            }
        }

        // There is no default-model slot any more: the detection card sits directly under the input slots, and the sample is the first catalog entry.
        LocalDetectionCard(board)

        // Release boundary: the desktop pairing producer has not shipped yet. The parser and the fingerprint state machine
        // are kept for later wiring; the Android release UI does not expose a pairing-code / QR entry that cannot be completed.

        // A connection failure reuses the existing failure row instead of adding a new card.
        if (board.failure == LocalSetupFailure.Connection) {
            viewModel.failure?.let { failure ->
                Text(
                    text = stringResource(failure.messageResource),
                    style = OriveoTheme.typography.footnote,
                    color = colors.error,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        if (board.showsManualPicker) {
            RelayRowGroup {
                RelayMenuRow(
                    title = stringResource(R.string.local_compute_engine),
                    value = viewModel.engine,
                    options = LocalEngineKind.entries,
                    label = { it.label },
                    enabled = !viewModel.isConnecting,
                    onSelect = {
                        stopDiscovery(LocalDiscoveryUiState.Idle)
                        viewModel.selectEngine(it)
                    },
                )
                if (board.showsChannelPicker) {
                    RelayRowDivider()
                    RelayMenuRow(
                        title = stringResource(R.string.local_setup_tile_channel),
                        value = viewModel.channel,
                        options = LocalEngineChannels.candidates(viewModel.engine.wireName).orEmpty(),
                        label = { it.localizedLabel() },
                        // The option attribution name is relay_setup_local_channel_menu_option.
                        enabled = !viewModel.isConnecting,
                        onSelect = viewModel::selectChannel,
                    )
                }
            }
        }
    }
}

@Composable
private fun LocalNetworkChips(chips: List<String>, selected: String, onSelect: (String) -> Unit) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(stringResource(R.string.local_setup_found_on_network), style = OriveoTheme.typography.footnote, color = colors.textSecondary)
        chips.forEach { chip ->
            val isSelected = chip.trimEnd('/') == selected.trim().trimEnd('/')
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (isSelected) colors.successSoft else colors.surfaceInset)
                    .clickable { onSelect(chip) }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SetupDot(if (isSelected) colors.success else colors.textTertiary)
                Text(chip.substringAfter("://"), style = OriveoTheme.typography.footnote, color = colors.textPrimary, maxLines = 1)
            }
        }
    }
}

@Composable
private fun LocalDetectionCard(board: LocalSetupBoard) {
    when (board.card) {
        SetupDetectionCard.Hidden -> Unit
        SetupDetectionCard.Detecting -> SetupDetectingCard(stringResource(board.detectingLabel))
        SetupDetectionCard.Succeeded -> board.summary?.let { summary ->
            SetupResultCard(success = true) {
                SetupCardTitleRow(
                    success = true,
                    title = pluralStringResource(
                        R.plurals.local_setup_recognized,
                        summary.modelCount,
                        summary.engine.label,
                        summary.modelCount,
                    ),
                    subtitle = null,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    LocalTile(stringResource(R.string.local_setup_tile_channel), summary.channel.localizedLabel(), Modifier.weight(1f))
                    LocalTile(
                        stringResource(R.string.local_setup_tile_context),
                        summary.contextLength?.let(::compactContextLength)
                            ?: stringResource(R.string.local_setup_value_unavailable),
                        Modifier.weight(1f),
                    )
                    LocalTile(stringResource(R.string.local_setup_tile_thinking), stringResource(summary.thinking.label), Modifier.weight(1f))
                }
            }
        }
        SetupDetectionCard.Failed -> if (board.failure == LocalSetupFailure.Unrecognized) {
            SetupResultCard(success = false) {
                SetupCardTitleRow(
                    success = false,
                    title = stringResource(R.string.local_setup_unrecognized_title),
                    subtitle = stringResource(R.string.local_setup_unrecognized_body),
                )
            }
        }
    }
}

@Composable
private fun LocalTile(title: String, value: String, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(OriveoTheme.radius.inset))
            .background(colors.surfaceInset)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(title, style = OriveoTheme.typography.footnote, color = colors.textSecondary, maxLines = 1)
        Text(value, style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary, maxLines = 2)
    }
}

internal val LocalEngineKind.label: String
    get() = when (this) {
        LocalEngineKind.LlamaCpp -> "llama.cpp"
        LocalEngineKind.Ollama -> "Ollama"
        LocalEngineKind.LmStudio -> "LM Studio"
        LocalEngineKind.Vllm -> "vLLM"
        LocalEngineKind.OpenWebUI -> "Open WebUI"
    }

private val LocalEngineConnectionFailure.messageResource: Int
    get() = when (this) {
        LocalEngineConnectionFailure.InvalidEndpoint -> R.string.local_compute_error_address
        LocalEngineConnectionFailure.CleartextCredentials -> R.string.local_compute_error_cleartext_credentials
        LocalEngineConnectionFailure.AuthenticationRejected -> R.string.relay_quick_auth_rejected
        LocalEngineConnectionFailure.WrongEngine -> R.string.local_compute_error_engine
        LocalEngineConnectionFailure.Loading -> R.string.local_compute_error_loading
        LocalEngineConnectionFailure.NoModels -> R.string.local_compute_error_models
        LocalEngineConnectionFailure.EngineStopped -> R.string.local_compute_error_stopped
        LocalEngineConnectionFailure.OutOfMemory -> R.string.local_compute_error_oom
        LocalEngineConnectionFailure.ContextExceeded -> R.string.local_compute_error_context
        LocalEngineConnectionFailure.Timeout -> R.string.local_compute_error_timeout
        LocalEngineConnectionFailure.Network -> R.string.local_compute_error_network
    }
