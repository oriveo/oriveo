package ai.oriveo.community.feature.providers.local

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.provider.LocalEngineConnectionFailure
import ai.oriveo.community.core.provider.LocalEngineContract
import ai.oriveo.community.core.provider.LocalEngineDiscoverySession
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.CustomLLMSetupCoordinator
import ai.oriveo.community.feature.providers.relay.RelayMenuRow
import ai.oriveo.community.feature.providers.relay.RelayRowGroup
import ai.oriveo.community.feature.providers.relay.RelaySecurityModeControl
import ai.oriveo.community.ui.component.OriveoLabeledField
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.launch
import org.koin.androidx.compose.koinViewModel

/** UI-only state for the optional LAN discovery affordance. */
private sealed interface LocalDiscoveryUiState {
    data object Idle : LocalDiscoveryUiState
    data object Scanning : LocalDiscoveryUiState
    data object Empty : LocalDiscoveryUiState
    data class Found(val endpoint: String) : LocalDiscoveryUiState
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
        val knownHost = runCatching { java.net.URI(viewModel.endpoint).host }.getOrNull()
            ?.takeUnless { it == "localhost" || it == "127.0.0.1" }
        discovery.start(
            scope = scope,
            knownHosts = listOfNotNull(knownHost),
            onResult = { result ->
                scope.launch {
                    if (discoveryState != LocalDiscoveryUiState.Scanning) return@launch
                    viewModel.updateEndpoint(result.endpoint)
                    stopDiscovery(LocalDiscoveryUiState.Found(result.endpoint))
                }
            },
            onComplete = {
                scope.launch {
                    if (discoveryState == LocalDiscoveryUiState.Scanning) {
                        stopDiscovery(LocalDiscoveryUiState.Empty)
                    }
                }
            },
        )
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xl),
    ) {
        Text(
            text = stringResource(R.string.local_compute_description),
            style = OriveoTheme.typography.body,
            color = OriveoTheme.colors.textSecondary,
        )

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
        }

        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.local_compute_address),
                    style = OriveoTheme.typography.caption,
                    color = OriveoTheme.colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    onClick = ::startDiscovery,
                    enabled = !viewModel.isConnecting,
                    modifier = Modifier.size(40.dp),
                ) {
                    Icon(
                        imageVector = if (discoveryState == LocalDiscoveryUiState.Scanning) Icons.Filled.Close else Icons.Filled.Search,
                        contentDescription = stringResource(
                            if (discoveryState == LocalDiscoveryUiState.Scanning) R.string.cancel else R.string.search,
                        ),
                        tint = OriveoTheme.colors.primary,
                    )
                }
            }
            OriveoLabeledField(
                label = "",
                value = viewModel.endpoint,
                onValueChange = {
                    stopDiscovery(LocalDiscoveryUiState.Idle)
                    viewModel.updateEndpoint(it)
                },
                placeholder = LocalEngineContract.templates.getValue(viewModel.engine).defaultEndpoint,
                enabled = !viewModel.isConnecting,
                selectionRange = viewModel.endpointHighlightRange,
                showLabel = false,
            )
            LocalDiscoveryStatus(state = discoveryState, onRetry = ::startDiscovery)
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
                color = OriveoTheme.colors.warning,
            )
        }

        if (viewModel.engine == LocalEngineKind.OpenWebUI) {
            OriveoLabeledField(
                label = stringResource(R.string.api_key),
                value = viewModel.apiKey,
                onValueChange = viewModel::updateApiKey,
                isSecure = true,
                enabled = !viewModel.isConnecting,
            )
        } else {
            Text(
                text = stringResource(R.string.local_compute_no_credentials),
                style = OriveoTheme.typography.footnote,
                color = OriveoTheme.colors.textSecondary,
            )
        }

        OriveoLabeledField(
            label = stringResource(R.string.local_compute_model_optional),
            value = viewModel.modelId,
            onValueChange = viewModel::updateModelId,
            enabled = !viewModel.isConnecting,
        )

        
        

        viewModel.failure?.let { failure ->
            Text(
                text = stringResource(failure.messageResource),
                style = OriveoTheme.typography.footnote,
                color = OriveoTheme.colors.error,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        if (viewModel.isConnectionVerified) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = OriveoTheme.colors.success,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = stringResource(R.string.snackbar_connection_verified),
                    style = OriveoTheme.typography.footnote,
                    color = OriveoTheme.colors.success,
                )
            }
        }
    }
}

@Composable
private fun LocalDiscoveryStatus(
    state: LocalDiscoveryUiState,
    onRetry: () -> Unit,
) {
    if (state == LocalDiscoveryUiState.Idle) return
    val colors = OriveoTheme.colors
    val isFound = state is LocalDiscoveryUiState.Found
    val isEmpty = state == LocalDiscoveryUiState.Empty
    val tone = when {
        isFound -> colors.success
        isEmpty -> colors.warning
        else -> colors.primary
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                color = when {
                    isFound -> colors.successSoft
                    isEmpty -> colors.warningSoft
                    else -> colors.primarySoft
                },
                shape = RoundedCornerShape(OriveoTheme.radius.md),
            )
            .then(if (isEmpty) Modifier.clickable(onClick = onRetry) else Modifier)
            .padding(horizontal = OriveoTheme.spacing.md, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        if (isFound) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = tone, modifier = Modifier.size(18.dp))
        }
        Text(
            text = when (state) {
                LocalDiscoveryUiState.Idle -> ""
                LocalDiscoveryUiState.Scanning -> stringResource(R.string.search)
                LocalDiscoveryUiState.Empty -> stringResource(R.string.local_compute_error_models)
                is LocalDiscoveryUiState.Found -> state.endpoint
            },
            style = OriveoTheme.typography.footnote,
            color = tone,
            modifier = Modifier.weight(1f),
        )
        if (isEmpty) {
            Text(
                text = stringResource(R.string.retry),
                style = OriveoTheme.typography.footnote,
                color = tone,
            )
        }
    }
}

private val LocalEngineKind.label: String
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
