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
    var endpoint by mutableStateOf("")
        private set
    var scenario by mutableStateOf(LocalComputeScenario.ThisDevice)
        private set
    var securityMode by mutableStateOf(defaultSecurityModeFor(engine))
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
        
        fun defaultSecurityModeFor(@Suppress("UNUSED_PARAMETER") engine: LocalEngineKind): RelayConnectionSecurityMode =
            RelayConnectionSecurityMode.RemoteHttps
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
        securityMode = defaultSecurityModeFor(value)
        if (value != LocalEngineKind.OpenWebUI) apiKey = ""
        endpointHighlightRange = null
        pairingCandidates = emptyList()
        pairingFingerprint = null
        failure = null
    }

    fun selectScenario(value: LocalComputeScenario) {
        invalidateConnectionAttempt()
        scenario = value
        if (value == LocalComputeScenario.AnotherComputer) endpoint = ""
        securityMode = defaultSecurityModeFor(engine)
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

    fun connect() {
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
        )
        failure = null
        completedProvider = null
        val job = viewModelScope.launch {
            try {
                val candidates = snapshot.pairingCandidates.ifEmpty {
                    listOf(LocalPairingCandidate(
                        snapshot.endpoint,
                        snapshot.securityMode,
                    ))
                }
                var lastError: LocalEngineConnectionException? = null
                val connection = candidates.firstNotNullOfOrNull { candidate ->
                    runCatching {
                        connector.connect(
                            snapshot.engine,
                            candidate.endpoint,
                            candidate.securityMode,
                            snapshot.modelId,
                            snapshot.apiKey,
                            snapshot.pairingFingerprint,
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
                verifiedSnapshot = snapshot
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
    )

}
