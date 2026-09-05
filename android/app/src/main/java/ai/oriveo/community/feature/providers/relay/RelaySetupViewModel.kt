package ai.oriveo.community.feature.providers.relay

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.RelayWebSearchToolName
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.provider.ProviderKeyInput
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.core.provider.RelayFormDraft
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelayDetectedConfiguration
import ai.oriveo.community.core.provider.RelayDetectionEvidence
import ai.oriveo.community.core.provider.RelayDiscoveryAttempt
import ai.oriveo.community.core.provider.RelayDiscoveryFailureKind
import ai.oriveo.community.core.provider.RelayDiscoveryResult
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.feature.providers.CustomLLMConnectionEvidence
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.CustomLLMSetupCoordinator
import ai.oriveo.community.feature.providers.CustomLLMSetupPhase
import ai.oriveo.community.feature.providers.CustomLLMVerificationEvidence
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

sealed interface RelaySetupCompletionTarget {
    data class ProviderDetail(val providerId: String) : RelaySetupCompletionTarget
    data class ManualModelEntry(val providerId: String) : RelaySetupCompletionTarget
}

fun relaySetupCompletionTarget(provider: Provider): RelaySetupCompletionTarget =
    if (provider.status is ProviderConnectionState.Connected) {
        RelaySetupCompletionTarget.ProviderDetail(providerId = provider.id)
    } else {
        RelaySetupCompletionTarget.ManualModelEntry(providerId = provider.id)
    }

enum class RelaySetupMode { Quick, Manual }

enum class RelayQuickAction { Detect, ConnectAndSave, SaveAndContinue }


class RelaySetupViewModel(
    private val context: Context,
    private val providerRepository: ProviderRepository,
    private val discoveryService: RelayDiscoveryService,
) : ViewModel() {

    companion object {
        fun normalizedRelayEndpoint(raw: String): String? = RelayEndpointPolicy.normalize(raw)
    }

    private fun requestSafeRelayEndpoint(raw: String): String? {
        
        
        if (raw != endpoint) return null
        val normalized = RelayFormValidation.normalizedEndpoint(formDraft, RelayFormValidation.FormMode.Create)
            ?: return null
        endpointHighlightRange = RelaySecurityModePolicy.addedSchemeHighlightRange(raw, normalized)
        if (normalized != endpoint) endpoint = normalized
        return normalized
    }

    var name: String by mutableStateOf("")
    var endpoint: String by mutableStateOf("")
    var endpointHighlightRange: IntRange? by mutableStateOf(null)
        private set
    
    val securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps
    var apiKey: String by mutableStateOf("")
    var defaultModel: String by mutableStateOf("")
        internal set
    var mode: RelaySetupMode by mutableStateOf(RelaySetupMode.Quick)
        private set
    var discoveryResult: RelayDiscoveryResult? by mutableStateOf(null)
        private set
    var selectedDetection: RelayDetectedConfiguration? by mutableStateOf(null)
        private set
    var discoveryFailureDetail: String? by mutableStateOf(null)
        private set
    var selectedRelayKind: RelayKind? by mutableStateOf(null)
    var customTransport: RelayTransport by mutableStateOf(RelayTransport.OpenAIChatCompletions)
    var customAuthMode: RelayAuthMode by mutableStateOf(RelayAuthMode.Bearer)
    var customReasoningEffort: RelayReasoningEffort by mutableStateOf(RelayReasoningEffort.Automatic)
    var customServiceTier: String by mutableStateOf("")
    var customStream: Boolean by mutableStateOf(true)
    var customDisableResponseStorage: Boolean by mutableStateOf(false)
    var customUserAgent: String by mutableStateOf("")
    var customHeaders: List<RelayKeyValue> by mutableStateOf(emptyList())
    var customQueryParams: List<RelayKeyValue> by mutableStateOf(emptyList())
    
    var customWebSearchToolName: RelayWebSearchToolName? by mutableStateOf(null)

    
    
    var customHasWebSearch: Boolean by mutableStateOf(false)
    
    var customWebSearchProfile: String? by mutableStateOf(null)
    
    var customTransportKindOverride: String? by mutableStateOf(null)

    var testConnectionResult: RelayConnectionTestResult? by mutableStateOf(null)
        private set

    var error: OriveoError? by mutableStateOf(null)
        private set

    var registeredProvider: Provider? by mutableStateOf(null)
        private set

    var completionTarget: RelaySetupCompletionTarget? by mutableStateOf(null)
        private set

    
    
    val customLLMCoordinator = CustomLLMSetupCoordinator()

    val isDiscovering: Boolean
        get() = customLLMCoordinator.phase == CustomLLMSetupPhase.Detecting
    val isSubmitting: Boolean
        get() = customLLMCoordinator.phase == CustomLLMSetupPhase.Saving
    val isTestingConnection: Boolean
        get() = customLLMCoordinator.phase == CustomLLMSetupPhase.Testing

    val detectedModelIDs: List<String>
        get() = selectedDetection?.modelIDs ?: discoveryResult?.detections?.firstOrNull()?.modelIDs.orEmpty()

    val quickAction: RelayQuickAction
        get() = when {
            selectedDetection?.generationVerified == true -> RelayQuickAction.ConnectAndSave
            discoveryResult?.detections?.isNotEmpty() == true && detectedModelIDs.isEmpty() ->
                RelayQuickAction.SaveAndContinue
            else -> RelayQuickAction.Detect
        }

    
    private val draftAuthMode: RelayAuthMode
        get() = when (val kind = selectedRelayKind) {
            null -> RelayAuthMode.Auto
            RelayKind.Custom -> customAuthMode
            else -> RelayKindDefaults.makeRequested(kind).authMode
        }

    
    val requiresCredential: Boolean
        get() = draftAuthMode.requiresCredential

    
    val formDraft: RelayFormDraft
        get() = RelayFormDraft(
            endpoint = endpoint,
            apiKey = apiKey,
            authMode = draftAuthMode,
            securityMode = securityMode,
            transport = customTransport,
            modelID = defaultModel,
            headers = customHeaders,
            queryParams = customQueryParams,
            hasSavedCredential = false,
        )

    
    val formIssues: List<RelayFormValidation.FieldIssue>
        get() = RelayFormValidation.validate(formDraft, RelayFormValidation.FormMode.Create)

    
    val displayableFormIssues: List<RelayFormValidation.FieldIssue>
        get() = RelayFormValidation.displayableIssues(formIssues)

    val canRunQuickAction: Boolean
        get() = formIssues.isEmpty() && !isDiscovering && !isSubmitting

    val defaultModelPlaceholder: String
        get() = MetadataClient.defaultModelId(ProviderKind.OpenAI) ?: "gpt-5.6-sol"

    val isChoosingRelayKind: Boolean
        get() = selectedRelayKind == null

    val canSubmit: Boolean
        get() = selectedRelayKind != null && formIssues.isEmpty() && !isSubmitting

    val canTestConnection: Boolean
        get() = selectedRelayKind != null &&
            formIssues.isEmpty() &&
            !isSubmitting &&
            !isTestingConnection

    override fun onCleared() {
        customLLMCoordinator.invalidate()
        super.onCleared()
    }

    fun updateEndpoint(value: String) {
        endpoint = value
        endpointHighlightRange = null
        clearDiscovery()
    }

    fun updateApiKey(value: String) {
        apiKey = value
        clearDiscovery()
    }

    fun updateDefaultModel(value: String) {
        defaultModel = value
        val isDetectedChoice = value.trim().let { selected ->
            selected.isNotEmpty() && detectedModelIDs.any { it == selected }
        }
        if (!isDetectedChoice) clearDiscovery()
    }

    fun showManualSetup() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Relay)
        mode = RelaySetupMode.Manual
        clearDiscovery()
    }

    fun showQuickSetup() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Relay)
        mode = RelaySetupMode.Quick
        selectedRelayKind = null
        clearDiscovery()
    }

    fun selectRelayMethod() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Relay)
        clearDiscovery()
        clearRelayCompletionForMethodChange()
    }

    fun selectLocalMethod() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Local)
        clearDiscovery()
        clearRelayCompletionForMethodChange()
    }

    private fun clearRelayCompletionForMethodChange() {
        registeredProvider = null
        completionTarget = null
        error = null
    }

    fun runQuickAction() {
        when (quickAction) {
            RelayQuickAction.Detect -> detectConnectionSettings()
            RelayQuickAction.ConnectAndSave -> saveDetectedRelay(verified = true)
            RelayQuickAction.SaveAndContinue -> saveDetectedRelay(verified = false)
        }
    }

    private fun detectConnectionSettings() {
        if (!canRunQuickAction) return
        if (apiKey.trim().let { it.isNotEmpty() && !ProviderKeyInput.isPrintableAsciiKey(it) }) {
            discoveryFailureDetail = context.getString(R.string.provider_api_key_illegal_chars)
            return
        }
        val normalizedEndpoint = requestSafeRelayEndpoint(endpoint) ?: return
        val attempt = customLLMCoordinator.begin(
            method = CustomLLMConnectionMethod.Relay,
            phase = CustomLLMSetupPhase.Detecting,
        )
        val job = viewModelScope.launch {
            try {
                val result = discoveryService.discover(
                    endpoint = normalizedEndpoint,
                    apiKey = apiKey.trim(),
                    modelHint = defaultModel.trim().takeIf(String::isNotEmpty),
                    relayRequested = formDraft.requestedConfigForPolicy(),
                )
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                discoveryResult = result
                if (result.detections.isEmpty()) {
                    discoveryFailureDetail = localizedDiscoveryFailure(result.blockingFailure)
                    customLLMCoordinator.acceptFailure(attempt)
                    return@launch
                }

                val catalogIDs = result.detections.first().modelIDs
                if (catalogIDs.isNotEmpty() && defaultModel.trim() !in catalogIDs) {
                    defaultModel = catalogIDs.first()
                }
                val modelID = defaultModel.trim()
                if (catalogIDs.isEmpty()) {
                    selectedDetection = result.detections.first()
                    customLLMCoordinator.acceptEvidence(
                        attempt,
                        CustomLLMConnectionEvidence(
                            
                            
                            verification = if (selectedDetection?.generationVerified == true) {
                                CustomLLMVerificationEvidence.GenerationVerified
                            } else {
                                CustomLLMVerificationEvidence.ManualModelRequired
                            },
                            catalogAvailable = false,
                        ),
                    )
                    customLLMCoordinator.finish(attempt)
                    return@launch
                }

                var finalFailure: String? = null
                for (detection in result.detections) {
                    if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                    val requested = detectedRequestedConfig(detection, modelID)
                    try {
                        providerRepository.pingRelayConnection(
                            apiKey = apiKey.trim(),
                            baseUrl = detection.apiBaseUrl,
                            modelID = modelID,
                            relayRequested = requested,
                            relayKind = relayKindFor(detection.transport),
                        )
                        if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                        selectedDetection = detection.copy(generationVerified = true)
                        discoveryFailureDetail = null
                        customLLMCoordinator.acceptEvidence(
                            attempt,
                            CustomLLMConnectionEvidence(
                                verification = CustomLLMVerificationEvidence.GenerationVerified,
                                catalogAvailable = true,
                            ),
                        )
                        customLLMCoordinator.finish(attempt)
                        return@launch
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                        finalFailure = stableRelayFailureMessage(error)
                    }
                }
                discoveryFailureDetail = finalFailure
                    ?: context.getString(R.string.relay_quick_no_protocol_verified)
                customLLMCoordinator.acceptFailure(attempt)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (customLLMCoordinator.isCurrent(attempt)) {
                    discoveryFailureDetail = stableRelayFailureMessage(error)
                    customLLMCoordinator.acceptFailure(attempt)
                }
            }
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }

    private fun saveDetectedRelay(verified: Boolean) {
        val detection = if (verified) selectedDetection else discoveryResult?.detections?.firstOrNull()
        if (detection == null || isSubmitting || !customLLMCoordinator.canCommit) return
        val attempt = customLLMCoordinator.beginCommit(CustomLLMConnectionMethod.Relay) ?: return
        val job = viewModelScope.launch {
            val normalizedEndpoint = requestSafeRelayEndpoint(endpoint) ?: run {
                customLLMCoordinator.acceptFailure(attempt)
                return@launch
            }
            error = null
            try {
                val modelID = defaultModel.trim().takeIf(String::isNotEmpty)
                val requested = detectedRequestedConfig(detection, modelID)
                val provider = providerRepository.registerRelayProvider(
                    apiKey = apiKey.trim(),
                    baseUrl = normalizedEndpoint,
                    customName = name.trim().takeIf(String::isNotEmpty),
                    relayKind = relayKindFor(detection.transport),
                    relayRequested = requested,
                    catalogModelIDs = detection.modelIDs,
                    preferredModelID = modelID,
                    preferredCapabilities = setOf(ModelCapability.Text).takeIf { modelID != null } ?: emptySet(),
                    connectionVerified = verified,
                    commitGuard = { customLLMCoordinator.canPersist(attempt) },
                )
                if (!customLLMCoordinator.canPersist(attempt)) return@launch
                if (!customLLMCoordinator.finishCommit(attempt)) return@launch
                registeredProvider = provider
                completionTarget = relaySetupCompletionTarget(provider)
            } catch (error: CancellationException) {
                throw error
            } catch (cause: Exception) {
                if (customLLMCoordinator.isCurrent(attempt)) {
                    error = OriveoError(
                        title = context.getString(R.string.provider_setup_failed_title),
                        message = stableRelayFailureMessage(cause),
                        severity = OriveoErrorSeverity.Critical,
                    )
                    customLLMCoordinator.acceptFailure(attempt)
                }
            }
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }

    private fun detectedRequestedConfig(
        detection: RelayDetectedConfiguration,
        modelID: String?,
    ): RelayRequestedConfig = RelayRequestedConfig(
        transport = detection.transport,
        authMode = detection.authMode,
        securityMode = securityMode,
        modelID = modelID,
        stream = true,
        disableResponseStorage = true.takeIf { detection.transport == RelayTransport.OpenAIResponses },
        codexCompatIdentity = true.takeIf { detection.transport == RelayTransport.OpenAIResponses },
        resolvedAPIBaseURL = detection.apiBaseUrl,
    )

    private fun relayKindFor(transport: RelayTransport): RelayKind = when (transport) {
        RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> RelayKind.OpenAICompatible
        RelayTransport.LlamaCppNative -> RelayKind.OpenAICompatible
        RelayTransport.OpenAIResponses -> RelayKind.CodexStyle
        RelayTransport.AnthropicMessages -> RelayKind.AnthropicCompatible
        RelayTransport.GeminiGenerateContent -> RelayKind.GeminiCompatible
    }

    private fun localizedDiscoveryFailure(failure: RelayDiscoveryFailureKind?): String = when (failure) {
        RelayDiscoveryFailureKind.EmbeddedQuery -> context.getString(R.string.relay_quick_embedded_query)
        RelayDiscoveryFailureKind.AuthenticationRejected -> context.getString(R.string.relay_quick_auth_rejected)
        RelayDiscoveryFailureKind.RateLimited -> context.getString(R.string.relay_quick_rate_limited)
        RelayDiscoveryFailureKind.TemporaryFailure -> context.getString(R.string.relay_quick_temporary_failure)
        RelayDiscoveryFailureKind.Network -> context.getString(R.string.relay_quick_network_failure)
        RelayDiscoveryFailureKind.InvalidEndpoint -> context.getString(R.string.relay_setup_invalid_endpoint_message)
        else -> context.getString(R.string.relay_quick_route_unavailable)
    }

    
    private fun stableRelayFailureMessage(error: Throwable): String = when (error) {
        is ProviderServiceError -> ErrorMapper.localizeProviderErrorMessage(error, context)
        else -> context.getString(R.string.error_generic_message)
    }

    private fun clearDiscovery(cancelRunning: Boolean = true) {
        
        if (cancelRunning) customLLMCoordinator.invalidate()
        discoveryResult = null
        selectedDetection = null
        discoveryFailureDetail = null
        testConnectionResult = null
    }

    fun selectRelayKind(kind: RelayKind) {
        selectedRelayKind = kind
        error = null
        testConnectionResult = null
    }

    fun returnToRelayKindPicker() {
        selectedRelayKind = null
        error = null
        testConnectionResult = null
    }

    fun testConnection() {
        val relayKind = selectedRelayKind ?: return
        if (!canTestConnection) {
            testConnectionResult = RelayConnectionTestResult(
                isSuccess = false,
                message = context.getString(R.string.relay_test_connection_missing_fields),
            )
            return
        }
        val attempt = customLLMCoordinator.begin(
            method = CustomLLMConnectionMethod.Relay,
            phase = CustomLLMSetupPhase.Testing,
        )
        val job = viewModelScope.launch {
            val normalizedEndpoint = requestSafeRelayEndpoint(endpoint)
            if (normalizedEndpoint == null) {
                val embeddedQuery = hasEmbeddedEndpointQuery(endpoint)
                testConnectionResult = RelayConnectionTestResult(
                    isSuccess = false,
                    message = context.getString(
                        if (embeddedQuery) {
                            R.string.relay_quick_embedded_query
                        } else {
                            R.string.relay_setup_invalid_endpoint_message
                        },
                    ),
                )
                customLLMCoordinator.acceptFailure(attempt)
                return@launch
            }
            if (!customLLMCoordinator.isCurrent(attempt)) return@launch

            
            if (apiKey.trim().let { it.isNotEmpty() && !ProviderKeyInput.isPrintableAsciiKey(it) }) {
                testConnectionResult = RelayConnectionTestResult(
                    isSuccess = false,
                    message = context.getString(R.string.provider_api_key_illegal_chars),
                )
                customLLMCoordinator.acceptFailure(attempt)
                return@launch
            }

            testConnectionResult = null
            try {
                val trimmedModel = defaultModel.trim().takeIf { it.isNotEmpty() }
                val relayRequested = buildRelayRequested(relayKind, trimmedModel)
                providerRepository.pingRelayConnection(
                    apiKey = apiKey.trim(),
                    baseUrl = normalizedEndpoint,
                    modelID = trimmedModel.orEmpty(),
                    relayRequested = relayRequested,
                    relayKind = relayKind,
                )
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                testConnectionResult = RelayConnectionTestResult(
                    isSuccess = true,
                    message = context.getString(R.string.relay_test_connection_success),
                )
                customLLMCoordinator.acceptEvidence(
                    attempt,
                    CustomLLMConnectionEvidence(
                        verification = CustomLLMVerificationEvidence.GenerationVerified,
                        catalogAvailable = false,
                    ),
                )
                customLLMCoordinator.finish(attempt)
            } catch (e: ProviderServiceError) {
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                testConnectionResult = RelayConnectionTestResult(
                    isSuccess = false,
                    message = ErrorMapper.localizeProviderErrorMessage(e, context),
                )
                customLLMCoordinator.acceptFailure(attempt)
            } catch (e: Exception) {
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                testConnectionResult = RelayConnectionTestResult(
                    isSuccess = false,
                    message = stableRelayFailureMessage(e),
                )
                customLLMCoordinator.acceptFailure(attempt)
            }
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }

    fun submit() {
        val relayKind = selectedRelayKind ?: return
        if (!canSubmit) return
        val attempt = customLLMCoordinator.begin(
            method = CustomLLMConnectionMethod.Relay,
            phase = CustomLLMSetupPhase.Testing,
        )

        val job = viewModelScope.launch {
            val normalizedEndpoint = requestSafeRelayEndpoint(endpoint)
            if (normalizedEndpoint == null) {
                
                
                error = OriveoError(
                    title = context.getString(R.string.relay_setup_invalid_endpoint_title),
                    message = context.getString(R.string.relay_setup_invalid_endpoint_message),
                    detail = endpoint.trim(),
                    severity = OriveoErrorSeverity.Warning,
                )
                customLLMCoordinator.acceptFailure(attempt)
                
                return@launch
            }

            
            if (apiKey.trim().let { it.isNotEmpty() && !ProviderKeyInput.isPrintableAsciiKey(it) }) {
                error = OriveoError(
                    title = context.getString(R.string.provider_api_key_illegal_chars_title),
                    message = context.getString(R.string.provider_api_key_illegal_chars),
                    detail = "",
                    severity = OriveoErrorSeverity.Warning,
                )
                customLLMCoordinator.acceptFailure(attempt)
                return@launch
            }

            error = null
            completionTarget = null
            try {
                val trimmedModel = defaultModel.trim().takeIf { it.isNotEmpty() }
                val relayRequested = buildRelayRequested(relayKind, trimmedModel)
                val trimmedApiKey = apiKey.trim()
                val trimmedName = name.trim().takeIf { it.isNotEmpty() }
                val preferredCapabilities = setOf(ModelCapability.Text).takeIf { trimmedModel != null } ?: emptySet()
                val connectionVerified = try {
                    providerRepository.pingRelayConnection(
                        apiKey = trimmedApiKey,
                        baseUrl = normalizedEndpoint,
                        modelID = trimmedModel.orEmpty(),
                        relayRequested = relayRequested,
                        relayKind = relayKind,
                    )
                    if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                    true
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                    false
                }
                val catalogIDs = if (connectionVerified) {
                    runCatching {
                        discoveryService.discover(
                            endpoint = normalizedEndpoint,
                            apiKey = trimmedApiKey,
                            modelHint = trimmedModel,
                            forcedTransport = relayRequested.transport,
                            includeGenerationProbe = false,
                            relayRequested = relayRequested,
                        ).detections.firstOrNull()?.modelIDs.orEmpty()
                    }.getOrDefault(emptyList())
                } else {
                    emptyList()
                }
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                if (!customLLMCoordinator.acceptEvidence(
                        attempt,
                        CustomLLMConnectionEvidence(
                            verification = if (connectionVerified) {
                                CustomLLMVerificationEvidence.GenerationVerified
                            } else {
                                CustomLLMVerificationEvidence.UnverifiedManual
                            },
                            catalogAvailable = catalogIDs.isNotEmpty(),
                        ),
                    )
                ) return@launch
                val persistAttempt = customLLMCoordinator.beginCommit(CustomLLMConnectionMethod.Relay) ?: return@launch
                val provider = providerRepository.registerRelayProvider(
                    apiKey = trimmedApiKey,
                    baseUrl = normalizedEndpoint,
                    customName = trimmedName,
                    relayKind = relayKind,
                    relayRequested = relayRequested,
                    catalogModelIDs = catalogIDs,
                    preferredModelID = trimmedModel,
                    preferredCapabilities = preferredCapabilities,
                    connectionVerified = connectionVerified,
                    commitGuard = { customLLMCoordinator.canPersist(persistAttempt) },
                )
                if (!customLLMCoordinator.canPersist(persistAttempt)) return@launch
                if (!customLLMCoordinator.finishCommit(persistAttempt)) return@launch
                registeredProvider = provider
                completionTarget = relaySetupCompletionTarget(provider)
                
            } catch (e: ProviderServiceError) {
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                error = OriveoError(
                    
                    title = ErrorMapper.localizeProviderErrorTitle(e.title, context),
                    message = ErrorMapper.localizeProviderErrorMessage(e, context),
                    detail = e.technicalDetail,
                    severity = OriveoErrorSeverity.Critical,
                )
                customLLMCoordinator.acceptFailure(attempt)
            } catch (e: Exception) {
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                error = OriveoError(
                    title = context.getString(R.string.provider_setup_failed_title),
                    message = stableRelayFailureMessage(e),
                    severity = OriveoErrorSeverity.Critical,
                )
                customLLMCoordinator.acceptFailure(attempt)
            }
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }


    private fun buildRelayRequested(relayKind: RelayKind, modelID: String?): RelayRequestedConfig {
        val preserving = RelayRequestedConfig(modelID = modelID?.trim()?.takeIf { it.isNotEmpty() })
        if (relayKind != RelayKind.Custom) {
            return RelayKindDefaults.makeRequested(relayKind, preserving = preserving).copy(
                authMode = draftAuthMode,
                securityMode = securityMode,
                resolvedAPIBaseURL = null,
            )
        }
        return RelayRequestedConfig(
            transport = customTransport,
            authMode = draftAuthMode,
            securityMode = securityMode,
            modelID = preserving.modelID,
            reasoningEffort = customReasoningEffort.takeIf { it != RelayReasoningEffort.Automatic },
            serviceTier = customServiceTier.trim().takeIf { it.isNotEmpty() },
            stream = customStream,
            disableResponseStorage = customDisableResponseStorage.takeIf { it },
            headers = customHeaders.cleanRelayPairs(),
            queryParams = customQueryParams.cleanRelayPairs(),
            customUserAgent = customUserAgent.trim().takeIf { it.isNotEmpty() },
            
            webSearchToolName = if (customTransport == RelayTransport.OpenAIResponses
                && customWebSearchToolName != null
                && customWebSearchToolName != RelayWebSearchToolName.WebSearch
            ) customWebSearchToolName else null,
            
            hasWebSearch = customHasWebSearch,
            webSearchProfile = customWebSearchProfile?.takeIf { customHasWebSearch && it.isNotBlank() },
            transportKind = customTransportKindOverride?.takeIf { it.isNotBlank() },
        )
    }

    private fun hasEmbeddedEndpointQuery(raw: String): Boolean = runCatching {
        RelayEndpointResolver.describe(raw).containsEmbeddedQuery
    }.getOrDefault(false)
}

private fun RelayConnectionSecurityMode.isCleartextMode(): Boolean =
    this == RelayConnectionSecurityMode.LocalHttp || this == RelayConnectionSecurityMode.PrivateVpn

private fun List<RelayKeyValue>.cleanRelayPairs(): List<RelayKeyValue>? {
    return mapNotNull { pair ->
        val key = pair.key.trim()
        val value = pair.value.trim()
        if (key.isEmpty() || value.isEmpty()) null else RelayKeyValue(key, value)
    }.ifEmpty { null }
}
