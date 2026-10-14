package ai.oriveo.community.feature.providers.local

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.provider.LocalEngineChannels
import ai.oriveo.community.core.provider.LocalEngineFingerprintOutcome
import ai.oriveo.community.core.provider.wireName
import ai.oriveo.community.R
import ai.oriveo.community.feature.providers.SetupBoardSlot
import ai.oriveo.community.feature.providers.SetupDetectionCard
import androidx.annotation.StringRes
import ai.oriveo.community.core.provider.LocalEngineConnectionException
import ai.oriveo.community.core.provider.LocalEngineConnectionFailure
import ai.oriveo.community.core.provider.LocalEngineConnection
import ai.oriveo.community.core.provider.LocalEngineConnector
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.core.provider.LocalEngineRuntimeClient
import ai.oriveo.community.core.provider.LocalRuntimeSnapshot
import ai.oriveo.community.core.provider.LocalPairingPayload
import ai.oriveo.community.core.provider.LocalPairingCandidate
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.feature.providers.CustomLLMConnectionEvidence
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.CustomLLMSetupCoordinator
import ai.oriveo.community.feature.providers.CustomLLMSetupPhase
import ai.oriveo.community.feature.providers.CustomLLMVerificationEvidence
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first

enum class LocalComputeScenario { ThisDevice, AnotherComputer, FullAddress }

enum class LocalComputeSecurityModeChangeResult { Applied, NeedsConfirmation, Rejected }

/** Primary button of the local add page: local has no Save and continue; detecting is represented by [LocalSetupBoard.isPrimaryLoading]. */
enum class LocalPrimaryAction { Detect, ConnectAndSave }

/** Values of the detection card's "Thinking" cell (engine-expectations.v1.json thinking.writePaths). */
enum class LocalThinkingValue(@StringRes val label: Int) {
    ChatTemplate(R.string.local_setup_thinking_template),
    SetByModel(R.string.local_setup_thinking_model),
    Unsupported(R.string.local_setup_value_unsupported),
}

/** Two kinds of detection failure: unrecognized fingerprint (generic / manual) uses the detection card; connection failure keeps the existing failure row. */
enum class LocalSetupFailure { Unrecognized, Connection }

data class LocalDetectionSummary(
    val engine: LocalEngineKind,
    val modelCount: Int,
    val channel: RelayTransport,
    /** Null when unavailable, shown as "N/A", never shown as 0. */
    val contextLength: Int?,
    val thinking: LocalThinkingValue,
)

/** Structural state of the local add page board (LocalSetup): the Screen only renders it. */
data class LocalSetupBoard(
    val slots: List<SetupBoardSlot>,
    val card: SetupDetectionCard,
    val summary: LocalDetectionSummary?,
    val failure: LocalSetupFailure?,
    val showsManualPicker: Boolean,
    val showsChannelPicker: Boolean,
    val primaryButton: LocalPrimaryAction,
    val isPrimaryEnabled: Boolean,
    val isPrimaryLoading: Boolean,
    val networkChips: List<String>,
    @StringRes val heroLabel: Int = R.string.local_setup_hero_label,
    @StringRes val heroTitle: Int = R.string.local_setup_hero_title,
    @StringRes val heroSubtitle: Int = R.string.local_setup_hero_subtitle,
    @StringRes val secondaryRow: Int = R.string.local_setup_manual_engine,
    @StringRes val detectingLabel: Int = R.string.relay_setup_detecting,
)

/** Thinking cell: check the write-path table first; only Ollama explicitly declaring no thinking means "unsupported", everything else is model default. */
internal fun localThinkingValue(
    engine: LocalEngineKind,
    channel: RelayTransport,
    declaration: EngineDeclaration?,
): LocalThinkingValue = when {
    LocalEngineChannels.thinkingWritable(engine.wireName, channel) == true -> LocalThinkingValue.ChatTemplate
    engine == LocalEngineKind.Ollama && declaration?.thinking == false -> LocalThinkingValue.Unsupported
    else -> LocalThinkingValue.SetByModel
}

/** Compact form of the context cell: 2048 -> 2K. */
internal fun compactContextLength(tokens: Int): String = when {
    tokens >= 1024 * 1024 && tokens % (1024 * 1024) == 0 -> "${tokens / (1024 * 1024)}M"
    tokens >= 1024 -> "${(tokens + 512) / 1024}K"
    else -> tokens.toString()
}

internal fun automaticPairingCandidates(
    candidates: List<LocalPairingCandidate>,
    fingerprint: String?,
): List<LocalPairingCandidate> = if (fingerprint.isNullOrBlank()) {
    emptyList()
} else {
    candidates.filter { it.securityMode == RelayConnectionSecurityMode.TofuHttps }
}

class LocalComputeSetupViewModel(
    private val connector: LocalEngineConnector,
    private val providerRepository: ProviderRepository,
    private val runtimeClient: LocalEngineRuntimeClient,
) : ViewModel() {

    private lateinit var coordinator: CustomLLMSetupCoordinator

    var engine by mutableStateOf(LocalEngineKind.Ollama)
        private set
    /** Connection-level channel; candidates come only from channels.byEngine (only llama.cpp has both chat / native). */
    var channel by mutableStateOf(RelayTransport.OpenAIChatCompletions)
        private set
    /** The user expanded manual selection (or it auto-expanded when the fingerprint was unrecognized): the primary button then skips fingerprinting and connects directly with the chosen engine and channel. */
    var showsManualPicker by mutableStateOf(false)
        private set
    private var isUnrecognized by mutableStateOf(false)
    /** Addresses discovered on the LAN; in-process only, used only for the chip row under the address slot. */
    var networkChips by mutableStateOf<List<String>>(emptyList())
        private set
    var endpoint by mutableStateOf("")
        private set
    var scenario by mutableStateOf(LocalComputeScenario.ThisDevice)
        private set
    var securityMode by mutableStateOf(DEFAULT_SECURITY_MODE)
        private set

    var endpointHighlightRange by mutableStateOf<IntRange?>(null)
        private set
    var modelId by mutableStateOf("")
        private set
    var apiKey by mutableStateOf("")
        private set
    var pairingCode by mutableStateOf("")
        private set
    private var pairingCandidates: List<LocalPairingCandidate> = emptyList()
    private var pairingFingerprint: String? = null
    val isConnecting: Boolean
        get() = activeCoordinator.phase == CustomLLMSetupPhase.Detecting ||
            activeCoordinator.phase == CustomLLMSetupPhase.Saving
    var failure by mutableStateOf<LocalEngineConnectionFailure?>(null)
        private set
    var completedProvider by mutableStateOf<Provider?>(null)
        private set
    private var verifiedConnection by mutableStateOf<LocalEngineConnection?>(null)
    private var verifiedSnapshot: ConnectionAttemptSnapshot? = null
    val isConnectionVerified: Boolean
        get() = verifiedConnection != null && verifiedSnapshot != null && activeCoordinator.canCommit
    var runtimeSnapshot by mutableStateOf(LocalRuntimeSnapshot())
        private set
    var isRefreshingRuntime by mutableStateOf(false)
        private set
    fun attachCoordinator(shared: CustomLLMSetupCoordinator) {
        if (::coordinator.isInitialized && coordinator === shared) return
        if (::coordinator.isInitialized) coordinator.invalidate()
        coordinator = shared
    }

    private val activeCoordinator: CustomLLMSetupCoordinator
        get() = check(::coordinator.isInitialized) {
            "Local compute fields require the Custom LLM coordinator"
        }.let { coordinator }

    companion object {
        /**
         * The security mode a newly configured local engine starts on.
         *
         * Every engine starts at the strictest setting regardless of which one it is; loosening it
         * to plain HTTP is an explicit choice the user makes in the form.
         */
        val DEFAULT_SECURITY_MODE: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps
    }

    val hasCredentialMaterial: Boolean
        get() = RelayEndpointPolicy.hasCredentialMaterial(
            requested = RelayRequestedConfig(
                authMode = if (engine == LocalEngineKind.OpenWebUI) RelayAuthMode.Bearer else RelayAuthMode.None,
                securityMode = securityMode,
            ),
            hasKey = apiKey.isNotBlank(),
        )

    fun selectEngine(value: LocalEngineKind) {
        invalidateConnectionAttempt()
        engine = value
        securityMode = DEFAULT_SECURITY_MODE
        if (value != LocalEngineKind.OpenWebUI) apiKey = ""
        endpointHighlightRange = null
        pairingCandidates = emptyList()
        pairingFingerprint = null
        failure = null
    }

    fun selectChannel(value: RelayTransport) {
        if (LocalEngineChannels.candidates(engine.wireName)?.contains(value) != true) return
        invalidateConnectionAttempt()
        channel = value
        failure = null
    }

    fun toggleManualPicker() {
        showsManualPicker = !showsManualPicker
    }

    fun addDiscoveredEndpoint(value: String) {
        if (value !in networkChips) networkChips = networkChips + value
    }

    fun clearDiscoveredEndpoints() {
        networkChips = emptyList()
    }

    val detectionCard: SetupDetectionCard
        get() = when {
            isConnecting && activeCoordinator.phase == CustomLLMSetupPhase.Detecting -> SetupDetectionCard.Detecting
            verifiedConnection != null -> SetupDetectionCard.Succeeded
            isUnrecognized || failure != null -> SetupDetectionCard.Failed
            else -> SetupDetectionCard.Hidden
        }

    val board: LocalSetupBoard
        get() {
            val card = detectionCard
            val connection = verifiedConnection.takeIf { card == SetupDetectionCard.Succeeded }
            return LocalSetupBoard(
                slots = listOfNotNull(
                    SetupBoardSlot.Address,
                    SetupBoardSlot.ApiKey.takeIf { engine == LocalEngineKind.OpenWebUI },
                ),
                card = card,
                summary = connection?.let {
                    // The channel is the one actually used for this connection (the snapshot and the connection settle together).
                    val connectedChannel = verifiedSnapshot?.channel ?: RelayTransport.OpenAIChatCompletions
                    LocalDetectionSummary(
                        engine = it.engine,
                        modelCount = it.modelIds.size,
                        channel = connectedChannel,
                        contextLength = it.contextLength,
                        thinking = localThinkingValue(it.engine, connectedChannel, it.engineDeclarations[it.selectedModelId]),
                    )
                },
                failure = when {
                    card != SetupDetectionCard.Failed -> null
                    isUnrecognized -> LocalSetupFailure.Unrecognized
                    else -> LocalSetupFailure.Connection
                },
                showsManualPicker = showsManualPicker,
                showsChannelPicker = showsManualPicker && LocalEngineChannels.showsSelector(engine.wireName) &&
                    LocalEngineChannels.candidates(engine.wireName) != null,
                primaryButton = if (isConnectionVerified) LocalPrimaryAction.ConnectAndSave else LocalPrimaryAction.Detect,
                isPrimaryEnabled = !isConnecting && endpoint.isNotBlank() &&
                    (engine != LocalEngineKind.OpenWebUI || apiKey.isNotBlank()),
                isPrimaryLoading = isConnecting,
                networkChips = networkChips,
            )
        }

    fun selectScenario(value: LocalComputeScenario) {
        invalidateConnectionAttempt()
        scenario = value
        if (value == LocalComputeScenario.AnotherComputer) endpoint = ""
        securityMode = DEFAULT_SECURITY_MODE
        endpointHighlightRange = null
        pairingCandidates = emptyList()
        pairingFingerprint = null
        failure = null
    }

    fun updateEndpoint(value: String) {
        invalidateConnectionAttempt()
        endpoint = value
        endpointHighlightRange = null
        pairingCandidates = emptyList()
        pairingFingerprint = null
        failure = null
    }

    fun updateModelId(value: String) {
        invalidateConnectionAttempt()
        modelId = value
        failure = null
    }

    fun updateApiKey(value: String) {
        invalidateConnectionAttempt()
        apiKey = value
        failure = null
    }

    fun updatePairingCode(value: String) {
        invalidateConnectionAttempt()
        pairingCode = value
        failure = null
    }

    fun setSecurityMode(
        mode: RelayConnectionSecurityMode,
        assessment: RelaySecurityModePolicy.Assessment,
        confirmDowngrade: Boolean = false,
    ): LocalComputeSecurityModeChangeResult {
        invalidateConnectionAttempt()
        if (mode == RelayConnectionSecurityMode.TofuHttps) return LocalComputeSecurityModeChangeResult.Rejected
        if (mode != RelayConnectionSecurityMode.RemoteHttps && !confirmDowngrade) {
            return LocalComputeSecurityModeChangeResult.NeedsConfirmation
        }
        val rawEndpoint = endpoint
        val normalized = RelaySecurityModePolicy.normalizedEndpoint(rawEndpoint, mode, assessment)
            ?: return LocalComputeSecurityModeChangeResult.Rejected

        endpoint = normalized
        endpointHighlightRange = RelaySecurityModePolicy.addedSchemeHighlightRange(rawEndpoint, normalized)
        securityMode = mode
        pairingCandidates = emptyList()
        pairingFingerprint = null
        if (mode != RelayConnectionSecurityMode.RemoteHttps) {
            if (hasCredentialMaterial) apiKey = ""
            if (engine == LocalEngineKind.OpenWebUI) {
                failure = LocalEngineConnectionFailure.CleartextCredentials
            }
        } else if (failure == LocalEngineConnectionFailure.CleartextCredentials) {
            failure = null
        }
        return LocalComputeSecurityModeChangeResult.Applied
    }

    fun applyPairingCode(connectImmediately: Boolean = false) {
        invalidateConnectionAttempt()
        val pairingCodeSnapshot = pairingCode
        runCatching { LocalPairingPayload.decode(pairingCodeSnapshot) }
            .onSuccess {
                if (it.authMode.value != "none") {
                    failure = LocalEngineConnectionFailure.InvalidEndpoint
                    return@onSuccess
                }
                engine = it.engine
                endpointHighlightRange = null
                val automaticCandidates = automaticPairingCandidates(it.candidates, it.fingerprint)
                if (automaticCandidates.isEmpty()) {

                    endpoint = it.endpoint
                    securityMode = RelayConnectionSecurityMode.RemoteHttps
                    pairingCandidates = emptyList()
                    pairingFingerprint = null
                } else {

                    endpoint = automaticCandidates.first().endpoint
                    securityMode = RelayConnectionSecurityMode.TofuHttps
                    pairingCandidates = automaticCandidates
                    pairingFingerprint = it.fingerprint
                }
                failure = null
                if (connectImmediately && securityMode == RelayConnectionSecurityMode.TofuHttps) connect()
            }
            .onFailure { failure = LocalEngineConnectionFailure.InvalidEndpoint }
    }

    /** Add page primary button: verified -> save; manual selection expanded -> connect directly; otherwise fingerprint first and let the recognized engine drive the connection. */
    fun runPrimaryAction() = startConnection(fingerprintFirst = !showsManualPicker)

    /** Connect with the currently selected engine and channel (no fingerprinting). */
    fun connect() = startConnection(fingerprintFirst = false)

    private fun startConnection(fingerprintFirst: Boolean) {
        if (isConnecting) return
        if (isConnectionVerified) {
            saveVerifiedConnection()
            return
        }
        val rawEndpoint = endpoint
        val credentials = RelayEndpointPolicy.Credentials(
            authMode = if (engine == LocalEngineKind.OpenWebUI) RelayAuthMode.Bearer else RelayAuthMode.None,
            hasKey = apiKey.isNotBlank(),
        )
        val normalizedCandidates = runCatching {
            val source = pairingCandidates.ifEmpty {
                listOf(LocalPairingCandidate(rawEndpoint, securityMode))
            }
            source.map { candidate ->
                candidate.copy(
                    endpoint = RelayEndpointPolicy.requireConfigured(
                        candidate.endpoint,
                        candidate.securityMode,
                        credentials,
                    ),
                )
            }
        }.getOrElse { error ->
            failure = LocalEngineConnector.configurationFailure(error)

            return
        }
        val normalizedEndpoint = normalizedCandidates.firstOrNull()?.endpoint ?: return
        endpoint = normalizedEndpoint
        endpointHighlightRange = RelaySecurityModePolicy.addedSchemeHighlightRange(rawEndpoint, normalizedEndpoint)
        val attempt = activeCoordinator.begin(
            method = CustomLLMConnectionMethod.Local,
            phase = CustomLLMSetupPhase.Detecting,
        )
        val snapshot = ConnectionAttemptSnapshot(
            engine = engine,
            endpoint = normalizedEndpoint,
            securityMode = securityMode,
            modelId = modelId,
            apiKey = apiKey,
            pairingCandidates = normalizedCandidates,
            pairingFingerprint = pairingFingerprint,
            channel = channel,
        )
        failure = null
        isUnrecognized = false
        completedProvider = null
        val job = viewModelScope.launch {
            try {
                val candidates = snapshot.pairingCandidates.ifEmpty {
                    listOf(LocalPairingCandidate(
                        snapshot.endpoint,
                        snapshot.securityMode,
                    ))
                }
                var attemptSnapshot = snapshot
                if (fingerprintFirst) {
                    val first = candidates.first()
                    val fingerprint = connector.fingerprint(first.endpoint, first.securityMode, snapshot.pairingFingerprint)
                    if (!activeCoordinator.isCurrent(attempt)) return@launch
                    val detected = fingerprint.engineProfile
                        ?.takeIf { fingerprint.outcome == LocalEngineFingerprintOutcome.Engine }
                        ?.let { profile -> LocalEngineKind.entries.firstOrNull { it.wireName == profile } }
                    if (detected == null) {
                        // generic / manual: if the engine is not recognized, do not guess; expand manual selection and let the user decide.
                        isUnrecognized = true
                        showsManualPicker = true
                        activeCoordinator.acceptFailure(attempt)
                        return@launch
                    }
                    engine = detected
                    channel = fingerprint.channel ?: RelayTransport.OpenAIChatCompletions
                    attemptSnapshot = snapshot.copy(engine = detected, channel = channel)
                }
                val connectSnapshot = attemptSnapshot
                var lastError: LocalEngineConnectionException? = null
                val connection = candidates.firstNotNullOfOrNull { candidate ->
                    runCatching {
                        connector.connect(
                            connectSnapshot.engine,
                            candidate.endpoint,
                            candidate.securityMode,
                            connectSnapshot.modelId,
                            connectSnapshot.apiKey,
                            connectSnapshot.pairingFingerprint,
                            connectSnapshot.channel,
                        )
                    }.onFailure { if (it is LocalEngineConnectionException) lastError = it }.getOrNull()
                } ?: throw lastError ?: LocalEngineConnectionException(LocalEngineConnectionFailure.Network)
                if (!activeCoordinator.isCurrent(attempt)) return@launch
                if (!activeCoordinator.acceptEvidence(
                        attempt,
                        CustomLLMConnectionEvidence(
                            verification = CustomLLMVerificationEvidence.GenerationVerified,
                            catalogAvailable = connection.modelIds.isNotEmpty(),
                        ),
                    )
                ) return@launch
                verifiedConnection = connection
                verifiedSnapshot = connectSnapshot
            } catch (error: CancellationException) {
                throw error
            } catch (error: LocalEngineConnectionException) {
                if (activeCoordinator.isCurrent(attempt)) {
                    failure = error.failure
                    activeCoordinator.acceptFailure(attempt)
                }
            } catch (_: Exception) {
                if (activeCoordinator.isCurrent(attempt)) {
                    failure = LocalEngineConnectionFailure.Network
                    activeCoordinator.acceptFailure(attempt)
                }
            } finally {
                if (activeCoordinator.isCurrent(attempt)) {
                    pairingCandidates = emptyList()
                    pairingFingerprint = null
                }
            }
        }
        activeCoordinator.registerCancellation(attempt, job)
    }

    fun cancelConnection() {
        invalidateConnectionAttempt()
    }

    fun clearCompletionForMethodChange() {
        completedProvider = null
        failure = null
    }

    private fun invalidateConnectionAttempt() {
        activeCoordinator.invalidate()
        verifiedConnection = null
        verifiedSnapshot = null
        isUnrecognized = false
    }

    private fun saveVerifiedConnection() {
        val connection = verifiedConnection ?: return
        val snapshot = verifiedSnapshot ?: return
        val persistAttempt = activeCoordinator.beginCommit(CustomLLMConnectionMethod.Local) ?: return
        completedProvider = null
        val job = viewModelScope.launch {
            try {
                val registered = providerRepository.registerRelayProvider(
                    apiKey = snapshot.apiKey,
                    baseUrl = connection.endpoint,
                    customName = snapshot.engine.displayName,
                    relayKind = RelayKind.OpenAICompatible,
                    relayRequested = connection.requested,
                    catalogModelIDs = connection.modelIds,
                    preferredModelID = connection.selectedModelId,
                    runtimeMetadata = connection.runtimeMetadata,
                    engineDeclarations = connection.engineDeclarations,
                    connectionVerified = true,
                    commitGuard = { activeCoordinator.canPersist(persistAttempt) },
                )
                if (!activeCoordinator.canPersist(persistAttempt)) return@launch
                if (!activeCoordinator.finishCommit(persistAttempt)) return@launch
                verifiedConnection = null
                verifiedSnapshot = null
                completedProvider = registered
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (activeCoordinator.isCurrent(persistAttempt)) {
                    failure = LocalEngineConnectionFailure.Network
                    activeCoordinator.acceptFailure(persistAttempt)
                    verifiedConnection = null
                    verifiedSnapshot = null
                }
            }
        }
        activeCoordinator.registerCancellation(persistAttempt, job)
    }

    fun refreshRuntime() {
        if (isRefreshingRuntime || endpoint.isBlank()) return
        isRefreshingRuntime = true
        viewModelScope.launch {
            runtimeSnapshot = runtimeClient.status(endpoint, engine, apiKey)
            isRefreshingRuntime = false
        }
    }

    fun promptCache(slotID: Int, action: String, cacheName: String) {
        viewModelScope.launch {
            runCatching { runtimeClient.promptCache(endpoint, slotID, action, cacheName) }
                .onFailure { failure = LocalEngineConnectionFailure.Network }
        }
    }

    private val LocalEngineKind.displayName: String
        get() = when (this) {
            LocalEngineKind.LlamaCpp -> "llama.cpp"
            LocalEngineKind.Ollama -> "Ollama"
            LocalEngineKind.LmStudio -> "LM Studio"
            LocalEngineKind.Vllm -> "vLLM"
            LocalEngineKind.OpenWebUI -> "Open WebUI"
        }

    private data class ConnectionAttemptSnapshot(
        val engine: LocalEngineKind,
        val endpoint: String,
        val securityMode: RelayConnectionSecurityMode,
        val modelId: String,
        val apiKey: String,
        val pairingCandidates: List<LocalPairingCandidate>,
        val pairingFingerprint: String?,
        val channel: RelayTransport = RelayTransport.OpenAIChatCompletions,
    )

}
