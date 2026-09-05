package ai.oriveo.community.feature.providers.detail

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.provider.BALANCE_CAPABLE_KINDS
import ai.oriveo.community.core.provider.BalanceQueryable
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.core.provider.ProviderBalanceRepository
import org.koin.core.component.KoinComponent
import org.koin.core.component.get
import org.koin.core.qualifier.named
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationParameterPresetStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability
import ai.oriveo.community.core.provider.grok.GrokSubscriptionTokens
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAvailability
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionTokens
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.isCleartextConnection
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.provider.ManualRetainedPruner
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.provider.ProviderKeyInput
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.ResolvedProviderCatalog
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.providers.relay.RelayConnectionTestResult
import ai.oriveo.community.feature.providers.relay.RelayEditFailurePresenter
import ai.oriveo.community.feature.providers.relay.relayRequestedMatchesPersisted
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * The single production rule for how much of a Relay edit needs re-verifying. The button label in the
 * UI and the save path itself must both consume this; letting the two sides guess separately is how
 * they end up disagreeing about which fields require a network round trip.
 */
internal data class RelayEditPlan(
    val requiresVerification: Boolean,
    val refreshCatalog: Boolean,
) {
    companion object {
        fun classify(
            persisted: Provider,
            candidateKind: RelayKind,
            candidateRequested: RelayRequestedConfig,
            candidateBaseUrl: String?,
            confirmedCatalogModels: List<AIModel>,
        ): RelayEditPlan {
            val persistedRequested = persisted.relayRequested ?: RelayRequestedConfig()
            val endpointChanged = persisted.baseUrlText?.trim()?.trimEnd('/') !=
                candidateBaseUrl?.trim()?.trimEnd('/')
            val kindChanged = persisted.relayKind != candidateKind
            val transportChanged = persistedRequested.transport != candidateRequested.transport
            val authChanged = persistedRequested.authMode != candidateRequested.authMode
            val securityChanged = persistedRequested.securityMode != candidateRequested.securityMode
            val modelChanged = persistedRequested.modelID?.trim().orEmpty() !=
                candidateRequested.modelID?.trim().orEmpty()
            val modelIsCatalogKnown = candidateRequested.modelID?.let { modelID ->
                ModelSelectionUtils.matchingModel(confirmedCatalogModels, modelID) != null
            } == true
            val refreshCatalog = endpointChanged || kindChanged || transportChanged ||
                authChanged || securityChanged
            return RelayEditPlan(
                requiresVerification = refreshCatalog || (modelChanged && !modelIsCatalogKnown),
                refreshCatalog = refreshCatalog,
            )
        }
    }
}

/**
 * Drives the provider detail screen: connection state, credential editing, and the model catalog.
 *
 * `metadataRefreshEventBus` is a required injection rather than a nullable fallback, and the
 * application-scoped coroutine scope is injected too. Holding a
 * `CoroutineScope(SupervisorJob() + Dispatchers.Default)` inside the ViewModel leaked coroutines;
 * `WhileSubscribed(5000)` still handles idle teardown on the subscriber side.
 */
class ProviderDetailViewModel(
    savedStateHandle: SavedStateHandle,
    private val providerRepository: ProviderRepository,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val metadataRefreshEventBus: MetadataRefreshEventBus,
    private val applicationScope: CoroutineScope,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val providerBalanceRepository: ProviderBalanceRepository? = null,
    // Dispatcher for the CPU work behind catalogGroups (dedupe, group, sort); tests inject a
    // TestDispatcher. Same arrangement as ProvidersViewModel.defaultDispatcher.
    private val defaultDispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val generationParameterSettingsStore: GenerationParameterSettingsStore? = null,
    private val capabilityPreferenceStore: ai.oriveo.community.core.model.CapabilityPreferenceStore? = null,
    private val localCustomFragmentStore: ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore? = null,
    private val generationParameterPresetStore: GenerationParameterPresetStore? = null,
) : ViewModel(), KoinComponent {
    private data class ResolvedCatalogSnapshot(
        val providerId: String,
        val catalog: ResolvedProviderCatalog,
    )

    enum class RelayCatalogUiState {
        Available,
        Loading,
        Failed,
        Empty,
    }

    private data class PendingRelayEdit(
        val candidate: Provider,
        val uiFailureMessage: String,
        val failureRevision: ProviderRepository.RelayEditRevision,
        val refreshCatalog: Boolean,
    )

    private val providerID: String = savedStateHandle["providerID"] ?: ""

    // Optimistic update: an action shows in the UI immediately instead of waiting for the Room Flow.
    private val _optimisticProvider = MutableStateFlow<Provider?>(null)

    val provider: StateFlow<Provider?> = combine(
        providerRepository.observeById(providerID),
        _optimisticProvider,
    ) { db, optimistic ->
        optimistic ?: db
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    /**
     * Immediate loading state for "verify connection".
     *
     * This deliberately does not reuse `provider.status is Syncing`. That state has to travel through
     * Room and back out via `combine().stateIn()`, and the StateFlow `stateIn` produces is conflated:
     * resync writes Syncing and then Connected in quick succession, so the Syncing frame is merged
     * away and the UI never observes it. A Compose snapshot value instead takes effect on the tap,
     * with no Room round trip.
     */
    var isResyncing: Boolean by mutableStateOf(false)
        private set

    var isTestingRelayConnection: Boolean by mutableStateOf(false)
        private set

    var relayConnectionTestResult: RelayConnectionTestResult? by mutableStateOf(null)
        private set
    private var relaySecurityModeGeneration: Long = 0L
    private var relaySecurityModeJob: kotlinx.coroutines.Job? = null
    private var relayConnectionTestGeneration: Long = 0L
    private var relayConnectionTestJob: kotlinx.coroutines.Job? = null
    private var relayEditGeneration: Long = 0L
    private var relayEditJob: Job? = null
    private var pendingRelayEdit: PendingRelayEdit? = null

    var isSavingRelaySettings: Boolean by mutableStateOf(false)
        private set

    var canSaveRelaySettingsUnverified: Boolean by mutableStateOf(false)
        private set

    private var relayCatalogTransientState: RelayCatalogUiState? by mutableStateOf(null)

    var showDeleteConfirm: Boolean by mutableStateOf(false)
    var showApiKeyEditor: Boolean by mutableStateOf(false)
    var showEndpointEditor: Boolean by mutableStateOf(false)

    var editingApiKey: String by mutableStateOf("")
    var apiKeyEditError: String? by mutableStateOf(null)
        private set
    var apiKeyEditErrorRes: Int? by mutableStateOf(null)
        private set
    var isUpdatingApiKey: Boolean by mutableStateOf(false)
        private set

    var selectedEndpointId: String by mutableStateOf("")
        private set
    var endpointEditError: String? by mutableStateOf(null)
        private set
    var endpointEditErrorRes: Int? by mutableStateOf(null)
        private set
    var isUpdatingEndpoint: Boolean by mutableStateOf(false)
        private set

    private val modelSearchQueryState = mutableStateOf("")
    private val modelSearchQueryFlow = MutableStateFlow("")

    var modelSearchQuery: String
        get() = modelSearchQueryState.value
        set(value) {
            if (modelSearchQueryState.value == value) return
            modelSearchQueryState.value = value
            modelSearchQueryFlow.value = value
        }

    var expandedGroups: Set<String> by mutableStateOf(emptySet())
        private set

    /**
     * Reactive catalog cache.
     *
     * Subscribes to `provider` plus `metadataRefreshSignal` so the resolver re-runs whenever the model
     * catalog refreshes. It runs on the injected application scope so a ViewModel rebuild does not
     * redo the work, and `WhileSubscribed(5000)` stops recomputing 5s after the last subscriber.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private val metadataRefreshSignal: Flow<Unit> =
        metadataRefreshEventBus.events.mapLatest { Unit }

    private val resolvedCatalogSnapshot: StateFlow<ResolvedCatalogSnapshot?> = combine(
        provider,
        metadataRefreshSignal,
    ) { current, _ ->
        current?.let {
            ResolvedCatalogSnapshot(
                providerId = it.id,
                catalog = ProviderCatalogResolver.resolve(it),
            )
        }
    }.stateIn(applicationScope, SharingStarted.WhileSubscribed(5000), null)

    val resolvedCatalog: StateFlow<ResolvedProviderCatalog?> = resolvedCatalogSnapshot
        .map { it?.catalog }
        .stateIn(applicationScope, SharingStarted.WhileSubscribed(5000), null)

    /**
     * The four offline states the catalog UI can be in.
     *
     * - Normal: the catalog loaded and is non-empty
     * - UsingCachedMetadata: hydrated from the local cache, with a banner saying the listing is from
     *   the last successful sync
     * - Offline: the catalog is unavailable and there are no manually retained models to fall back on
     * - ManualRetainedOnly: manually retained models exist but the catalog itself is empty
     */
    enum class CatalogViewState {
        Normal,
        UsingCachedMetadata,
        Offline,
        ManualRetainedOnly,
    }

    /**
     * The only place the three Relay catalog states are derived for the UI. Failed is decided solely
     * by the repository's canonical soft key; a stale non-empty catalogModels must not masquerade as
     * Available. The connection card still reads status and nothing else.
     */
    fun relayCatalogUiState(provider: Provider): RelayCatalogUiState {
        relayCatalogTransientState?.let { return it }
        return when {
            provider.lastError == ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE ->
                RelayCatalogUiState.Failed
            provider.catalogModels.isNotEmpty() -> RelayCatalogUiState.Available
            else -> RelayCatalogUiState.Empty
        }
    }

    internal fun relayEditPlan(
        provider: Provider,
        relayKind: RelayKind,
        relayRequested: RelayRequestedConfig,
        baseUrlText: String?,
    ): RelayEditPlan = RelayEditPlan.classify(
        persisted = provider,
        candidateKind = relayKind,
        candidateRequested = relayRequested,
        candidateBaseUrl = baseUrlText,
        confirmedCatalogModels = if (relayCatalogUiState(provider) == RelayCatalogUiState.Available) {
            provider.catalogModels
        } else {
            emptyList()
        },
    )

    /**
     * Catalog view state, derived from the resolver result plus the catalog's contract version and
     * source.
     *
     * `combine(resolvedCatalog, provider)` guarantees both StateFlows are read in the same frame.
     * Reading `provider.value` directly would let a burst of updates pair a stale provider with a
     * fresh `resolved`.
     */
    val catalogViewState: StateFlow<CatalogViewState> = combine(
        resolvedCatalog,
        provider,
    ) { resolved, p ->
        val source = MetadataClient.metadataSource
        when {
            p == null -> CatalogViewState.Normal
            p.kind == ProviderKind.Relay -> CatalogViewState.Normal
            // Catalog not loaded and nothing manually retained: fully offline.
            resolved == null || (resolved.catalog.isEmpty() && !resolved.hasManualModels) ->
                CatalogViewState.Offline
            // Catalog unavailable, but manually retained models can stand in.
            resolved.catalog.all { it.isManual } -> CatalogViewState.ManualRetainedOnly
            // Serving a cached catalog with no fresher fetch behind it.
            source == MetadataClient.MetadataSource.CachedOffline -> CatalogViewState.UsingCachedMetadata
            else -> CatalogViewState.Normal
        }
    }.stateIn(applicationScope, SharingStarted.WhileSubscribed(5000), CatalogViewState.Normal)

    @OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
    val catalogGroups: StateFlow<List<ProviderCatalogGroup>?> = combine(
        provider,
        resolvedCatalogSnapshot,
        // Debounce the search box by 120ms and drop repeats, so a keystroke does not trigger a full
        // resolve plus dedupe, group and sort. On an aggregated provider with 400+ models that work is
        // significant on the main thread.
        modelSearchQueryFlow.debounce(120L).distinctUntilChanged(),
    ) { current, snapshot, searchQuery ->
        Triple(current, snapshot, searchQuery)
    }.mapLatest { (current, snapshot, searchQuery) ->
        val currentProvider = current ?: return@mapLatest null
        val usesModelLibrary = currentProvider.kind.isAggregatedProvider ||
            (currentProvider.kind == ProviderKind.Relay && currentProvider.catalogModels.isNotEmpty())
        if (!usesModelLibrary) {
            return@mapLatest null
        }

        val resolved = snapshot
            ?.takeIf { it.providerId == currentProvider.id }
            ?.catalog
            ?: return@mapLatest null

        buildProviderCatalogGroups(
            provider = currentProvider,
            resolvedCatalog = resolved,
            searchQuery = searchQuery,
        )
    }
        // The debounce only covers keystrokes, not the one full computation on first opening the page.
        // For an aggregated provider with 400+ models, the dedupe plus two groupBy passes plus the
        // scoring sort dropped frames reliably on low-end devices when they ran on viewModelScope's
        // default Main dispatcher. Moving the whole chain to defaultDispatcher keeps it on the same
        // side as resolvedCatalogSnapshot, which already runs on the application scope.
        .flowOn(defaultDispatcher)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    init {
        // Refresh the balance automatically after the API key or the regional endpoint changes.
        viewModelScope.launch {
            var previousSource: Pair<String, String?>? = null
            provider.filterNotNull().collect { p ->
                val currentSource = p.apiKey to p.baseUrlText
                if (previousSource != null && currentSource != previousSource) {
                    refreshBalance()
                }
                previousSource = currentSource
            }
        }
    }

    /**
     * Verifies the connection and refreshes the model catalog.
     *
     * Repository.resyncProvider swallows every non-cancellation exception internally and records the
     * outcome on provider.status (Connected when a cache exists, Issue when it does not). So the
     * ViewModel cannot judge success by whether a call threw; it has to read the status the provider
     * Flow pushes back after the resync. Issue means failure and raises a failure snackbar.
     *
     * The outer catch is a safety net in case the repository is ever changed to rethrow, so
     * viewModelScope does not crash.
     */
    fun resync() {
        if (isResyncing) return
        viewModelScope.launch {
            isResyncing = true
            try {
                val current = providerRepository.observeById(providerID).filterNotNull().first()
                if (current.kind == ProviderKind.Relay) {
                    // A plain re-verify only spends a 1-token probe; retrying the catalog has its own entry point.
                    providerRepository.reverifyRelayProvider(providerID)
                } else {
                    providerRepository.resyncProvider(providerID)
                }
                // Read the final status and lastError the repository wrote to decide the outcome:
                //   Issue                        -> failed (error toast)
                //   Connected + soft message     -> unverified (warning toast, lastError carries why)
                //   Connected, no soft message   -> success (success toast)
                // Subscribe to the repository Flow rather than reading `provider.value`: combine plus
                // stateIn is scheduled asynchronously, so the cached value can still be the old one.
                val finalProvider = providerRepository.observeById(providerID).filterNotNull().first()
                val status = finalProvider.status
                val softError = finalProvider.lastError?.trim().orEmpty()
                when {
                    status is ProviderConnectionState.Issue -> emitResyncFailed(status.message)
                    softError.isNotEmpty() -> globalSnackbarManager.show(
                        GlobalSnackbarMessage(
                            message = UiText.Dynamic(localizeProviderStatusDetail(softError)),
                            style = GlobalToastStyle.Warning,
                        ),
                    )
                    else -> globalSnackbarManager.show(
                        GlobalSnackbarMessage(
                            message = UiText.Resource(R.string.snackbar_connection_verified),
                            style = GlobalToastStyle.Success,
                        ),
                    )
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                relayCatalogTransientState = null
                val providerError = e as? ProviderServiceError
                emitResyncFailed(
                    providerError?.let(::localizedRelayFailure) ?: e.message.orEmpty(),
                )
            } finally {
                isResyncing = false
            }
        }
    }

    fun retryRelayCatalog() {
        val current = provider.value ?: return
        if (current.kind != ProviderKind.Relay || isResyncing) return
        viewModelScope.launch {
            isResyncing = true
            relayCatalogTransientState = RelayCatalogUiState.Loading
            try {
                val outcome = providerRepository.refreshRelayCatalogOnly(providerID)
                if (outcome.stale) {
                    relayCatalogTransientState = null
                    return@launch
                }
                outcome.provider?.let { _optimisticProvider.value = it }
                relayCatalogTransientState = when {
                    !outcome.catalogSucceeded -> RelayCatalogUiState.Failed
                    outcome.provider?.catalogModels.isNullOrEmpty() -> RelayCatalogUiState.Empty
                    else -> RelayCatalogUiState.Available
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                relayCatalogTransientState = RelayCatalogUiState.Failed
            } finally {
                isResyncing = false
            }
        }
    }

    private fun emitResyncFailed(detail: String) {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(
                    R.string.snackbar_connection_check_failed,
                    listOf(localizeProviderStatusDetail(detail)),
                ),
                style = GlobalToastStyle.Error,
            ),
        )
    }

    
    private fun localizeProviderStatusDetail(detail: String): String =
        runCatching {
            ErrorMapper.localizeProviderErrorMessage(detail, get<android.content.Context>())
        }.getOrDefault(detail)

    fun testRelayConnection(
        provider: Provider,
        relayKind: RelayKind,
        relayRequested: RelayRequestedConfig,
        endpoint: String,
        modelID: String,
    ) {
        if (provider.kind != ProviderKind.Relay || isTestingRelayConnection) return
        val trimmedEndpoint = endpoint.trim()
        val trimmedModelID = modelID.trim().ifEmpty { provider.defaultModel?.id.orEmpty() }
        
        val missingCredential = requiresCredential(provider) && !hasStoredKey(provider)
        if (trimmedEndpoint.isEmpty() || trimmedModelID.isEmpty() || missingCredential) {
            relayConnectionTestResult = RelayConnectionTestResult(
                isSuccess = false,
                message = "",
            )
            return
        }
        val normalizedEndpoint = runCatching {
            RelayEndpointPolicy.requireConfigured(
                baseUrl = trimmedEndpoint,
                securityMode = relayRequested.securityMode,
                credentials = RelayEndpointPolicy.credentialsOf(
                    requested = relayRequested,
                    hasKey = hasStoredKey(provider),
                ),
            )
        }.getOrNull()
        if (normalizedEndpoint == null) {
            relayConnectionTestResult = RelayConnectionTestResult(
                isSuccess = false,
                message = localizeProviderStatusDetail(RelayEndpointPolicy.HTTPS_REQUIRED_MESSAGE),
            )
            return
        }
        relayConnectionTestJob?.cancel()
        val generation = ++relayConnectionTestGeneration
        val apiKeySnapshot = provider.apiKey
        val requestedSnapshot = relayRequested.copy(modelID = trimmedModelID)
        val isPersistedConnection = isPersistedRelayConnection(
            provider = provider,
            relayKind = relayKind,
            relayRequested = requestedSnapshot,
            normalizedEndpoint = normalizedEndpoint,
            modelID = trimmedModelID,
        )
        var failureCandidate = provider.copy(
            apiKey = apiKeySnapshot,
            baseUrlText = normalizedEndpoint,
            relayKind = relayKind,
            relayRequested = requestedSnapshot,
        )
        relayConnectionTestJob = viewModelScope.launch {
            isTestingRelayConnection = true
            relayConnectionTestResult = null
            try {
                if (isPersistedConnection) {
                    val outcome = providerRepository.verifyPersistedRelayGeneration(providerID)
                    if (generation != relayConnectionTestGeneration) return@launch
                    failureCandidate = outcome.attemptedProvider ?: failureCandidate
                    if (outcome.stale) return@launch
                    outcome.error?.let { throw it }
                } else {
                    providerRepository.verifyRelayGeneration(
                        apiKey = apiKeySnapshot,
                        baseUrl = normalizedEndpoint,
                        modelID = trimmedModelID,
                        relayRequested = requestedSnapshot,
                        relayKind = relayKind,
                    )
                }
                if (generation != relayConnectionTestGeneration) return@launch
                relayConnectionTestResult = RelayConnectionTestResult(
                    isSuccess = true,
                    message = "",
                )
            } catch (e: ProviderServiceError) {
                if (generation != relayConnectionTestGeneration) return@launch
                relayConnectionTestResult = RelayConnectionTestResult(
                    isSuccess = false,
                    
                    message = localizedRelayFailure(e),
                    failurePresentation = RelayEditFailurePresenter.present(failureCandidate, e),
                )
            } catch (e: Exception) {
                if (generation != relayConnectionTestGeneration) return@launch
                relayConnectionTestResult = RelayConnectionTestResult(
                    isSuccess = false,
                    message = localizedRelayFailure(e),
                    failurePresentation = RelayEditFailurePresenter.present(failureCandidate, e),
                )
            } finally {
                if (generation == relayConnectionTestGeneration) {
                    isTestingRelayConnection = false
                    relayConnectionTestJob = null
                }
            }
        }
    }

    
    private fun isPersistedRelayConnection(
        provider: Provider,
        relayKind: RelayKind,
        relayRequested: RelayRequestedConfig,
        normalizedEndpoint: String,
        modelID: String,
    ): Boolean {
        val persistedRequested = provider.relayRequested ?: return false
        val persistedModelID = persistedRequested.modelID.orEmpty().ifBlank {
            provider.defaultModel?.id.orEmpty()
        }
        return provider.relayKind == relayKind &&
            provider.baseUrlText?.trimEnd('/') == normalizedEndpoint.trimEnd('/') &&
            persistedModelID == modelID &&
            relayRequestedMatchesPersisted(
                relayKind = relayKind,
                persisted = persistedRequested.copy(modelID = persistedModelID),
                candidate = relayRequested,
            )
    }

    
    fun invalidateRelayConnectionTest() {
        relaySecurityModeGeneration += 1
        relayConnectionTestGeneration += 1
        relayEditGeneration += 1
        relaySecurityModeJob?.cancel()
        relaySecurityModeJob = null
        relayConnectionTestJob?.cancel()
        relayConnectionTestJob = null
        relayEditJob?.cancel()
        relayEditJob = null
        isSavingRelaySettings = false
        pendingRelayEdit = null
        canSaveRelaySettingsUnverified = false
        relayCatalogTransientState = null
        isTestingRelayConnection = false
        relayConnectionTestResult = null
    }

    
    fun changeRelaySecurityMode(
        provider: Provider,
        mode: RelayConnectionSecurityMode,
        normalizedEndpoint: String,
    ) {
        if (provider.kind != ProviderKind.Relay || mode == RelayConnectionSecurityMode.TofuHttps) return
        val existingRequested = provider.relayRequested ?: RelayRequestedConfig()
        if (existingRequested.securityMode == mode) {
            relayConnectionTestResult = null
            return
        }
        val cleartext = mode == RelayConnectionSecurityMode.LocalHttp ||
            mode == RelayConnectionSecurityMode.PrivateVpn
        val hadStoredKey = hasStoredKey(provider)
        val hasPersistedCredentialMaterial = RelayEndpointPolicy.hasCredentialMaterial(
            requested = existingRequested,
            hasKey = hadStoredKey,
        )
        val nextRequested = existingRequested.copy(
            authMode = if (cleartext) RelayAuthMode.None else existingRequested.authMode,
            securityMode = mode,
            headers = if (cleartext && hasPersistedCredentialMaterial) null else existingRequested.headers,
            queryParams = if (cleartext && hasPersistedCredentialMaterial) null else existingRequested.queryParams,
            
            resolvedAPIBaseURL = null,
        )
        val effectiveKey = if (cleartext) "" else provider.apiKey
        val validatedEndpoint = try {
            RelayEndpointPolicy.requireConfigured(
                baseUrl = normalizedEndpoint,
                securityMode = mode,
                credentials = RelayEndpointPolicy.credentialsOf(
                    requested = nextRequested,
                    hasKey = hasStoredCredential(effectiveKey),
                ),
            )
        } catch (error: ProviderServiceError.InvalidConfiguration) {
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(relaySaveBlockedMessageRes(error.detail)),
                    style = GlobalToastStyle.Error,
                ),
            )
            return
        }
        val issueProvider = provider.copy(
            apiKey = effectiveKey,
            apiKeyPreview = SecureKeyStore.maskApiKey(effectiveKey),
            baseUrlText = validatedEndpoint,
            relayRequested = nextRequested,
            status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
            lastError = ProviderRepository.RELAY_UNVERIFIED_MESSAGE,
            
            models = emptyList(),
            catalogModels = emptyList(),
            lastCheckedAt = null,
            cachedAvailableModelCount = null,
        )
        invalidateRelayConnectionTest()
        val generation = ++relaySecurityModeGeneration
        _optimisticProvider.value = issueProvider
        relayConnectionTestResult = null

        relaySecurityModeJob = viewModelScope.launch {
            if (generation != relaySecurityModeGeneration) return@launch
            isTestingRelayConnection = true
            try {
                if (cleartext && hadStoredKey) {
                    if (generation != relaySecurityModeGeneration) return@launch
                    providerRepository.updateApiKey(providerID, "")
                }
                if (generation != relaySecurityModeGeneration) return@launch
                providerRepository.updateProvider(issueProvider)
                if (generation != relaySecurityModeGeneration) return@launch

                val modelID = provider.defaultModel?.id.orEmpty()
                val pingFailure = runCatching {
                    providerRepository.pingRelayConnection(
                        apiKey = effectiveKey,
                        baseUrl = validatedEndpoint,
                        modelID = modelID,
                        relayRequested = nextRequested.copy(modelID = modelID.ifBlank { nextRequested.modelID }),
                        relayKind = provider.relayKind,
                    )
                }.exceptionOrNull()
                if (generation != relaySecurityModeGeneration) return@launch

                
                
                val catalogOutcome = providerRepository.resyncProviderForModeTransition(providerID) {
                    generation == relaySecurityModeGeneration
                }
                if (generation != relaySecurityModeGeneration) return@launch
                if (catalogOutcome.stale) return@launch
                var finalProvider = catalogOutcome.provider ?: issueProvider
                if (pingFailure != null) {
                    val detail = localizedRelayFailure(pingFailure)
                    finalProvider = finalProvider.copy(
                        status = ProviderConnectionState.Issue(detail),
                        lastError = detail,
                    )
                    providerRepository.updateProvider(finalProvider)
                }
                if (generation != relaySecurityModeGeneration) return@launch
                _optimisticProvider.value = finalProvider
                relayConnectionTestResult = RelayConnectionTestResult(
                    isSuccess = pingFailure == null && catalogOutcome.catalogSucceeded &&
                        finalProvider.status !is ProviderConnectionState.Issue,
                    message = when {
                        pingFailure != null -> localizedRelayFailure(pingFailure)
                        catalogOutcome.error != null -> localizedRelayFailure(catalogOutcome.error)
                        else -> ""
                    },
                )
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: Exception) {
                if (generation == relaySecurityModeGeneration) {
                    val detail = localizedRelayFailure(error)
                    val failed = issueProvider.copy(
                        status = ProviderConnectionState.Issue(detail),
                        lastError = detail,
                    )
                    runCatching { providerRepository.updateProvider(failed) }
                    _optimisticProvider.value = failed
                    relayConnectionTestResult = RelayConnectionTestResult(false, detail)
                }
            } finally {
                if (generation == relaySecurityModeGeneration) {
                    isTestingRelayConnection = false
                    relaySecurityModeJob = null
                }
            }
        }
    }

    private fun localizedRelayFailure(error: Throwable): String {
        val providerError = error as? ProviderServiceError
        val source = providerError?.userMessage ?: ProviderRepository.RELAY_UNVERIFIED_MESSAGE
        return runCatching {
            val context = get<android.content.Context>()
            providerError?.let { ErrorMapper.localizeProviderErrorMessage(it, context) }
                ?: ErrorMapper.localizeProviderErrorMessage(source, context)
        }.getOrDefault(source)
    }

    

    
    sealed interface BalanceUiState {
        data object Hidden : BalanceUiState
        
        data object Loading : BalanceUiState
        
        data class Loaded(val balance: ProviderBalance, val isRefreshing: Boolean = false) : BalanceUiState
        data class Error(val detail: String) : BalanceUiState
        data class KeyInvalid(val detail: String) : BalanceUiState
    }

    private val balanceCacheTtlMs = 5 * 60 * 1000L
    private val _balanceState = MutableStateFlow<BalanceUiState>(BalanceUiState.Hidden)
    val balanceState: StateFlow<BalanceUiState> = _balanceState

    val managedWalletState: StateFlow<Any?> = MutableStateFlow(null)

    val managedWeeklyQuotaOffer: StateFlow<Any?> = MutableStateFlow(null)

    private var managedBalanceRefreshJob: Job? = null
    private var managedBalanceRefreshOwnerKey: String? = null
    private var managedBalanceRefreshGeneration = 0

    
    fun ensureBalanceLoaded() {
        val current = provider.value ?: return
        if (current.kind !in BALANCE_CAPABLE_KINDS) {
            _balanceState.value = BalanceUiState.Hidden
            return
        }
        val cached = (_balanceState.value as? BalanceUiState.Loaded)?.balance
        if (cached != null) {
            val ageMs = java.time.Duration.between(cached.fetchedAt, java.time.Instant.now()).toMillis()
            if (ageMs < balanceCacheTtlMs) return
        }
        refreshBalance(forceRefresh = false)
    }

    
    fun refreshBalance(forceRefresh: Boolean = true) {
        val current = provider.value ?: return
        if (current.kind !in BALANCE_CAPABLE_KINDS) {
            _balanceState.value = BalanceUiState.Hidden
            return
        }
        val service = if (providerBalanceRepository == null) {
            balanceServiceFor(current.kind)
        } else {
            null
        }
        if (providerBalanceRepository == null && service == null) {
            _balanceState.value = BalanceUiState.Hidden
            return
        }
        val apiKey = current.apiKey
        if (!hasStoredCredential(apiKey)) {
            _balanceState.value = BalanceUiState.KeyInvalid("API key is empty.")
            return
        }
        
        val previousBalance = (_balanceState.value as? BalanceUiState.Loaded)?.balance
        _balanceState.value = if (previousBalance != null) {
            BalanceUiState.Loaded(balance = previousBalance, isRefreshing = true)
        } else {
            BalanceUiState.Loading
        }
        viewModelScope.launch {
            try {
                val balance = providerBalanceRepository?.fetchBalance(current, forceRefresh)
                    ?: requireNotNull(service).fetchBalance(apiKey, current.baseUrlText)
                _balanceState.value = BalanceUiState.Loaded(balance = balance, isRefreshing = false)
            } catch (e: kotlinx.coroutines.CancellationException) {
                if (previousBalance != null) {
                    _balanceState.value = BalanceUiState.Loaded(balance = previousBalance, isRefreshing = false)
                }
                throw e
            } catch (e: ProviderServiceError.InvalidAPIKey) {
                
                _balanceState.value = when {
                    current.kind == ProviderKind.OpenRouter -> BalanceUiState.Hidden
                    previousBalance != null -> BalanceUiState.Loaded(previousBalance, isRefreshing = false)
                    else -> BalanceUiState.KeyInvalid(e.detail)
                }
            } catch (e: ProviderServiceError.Upstream) {
                _balanceState.value = when {
                    e.statusCode == 401 || e.statusCode == 403 -> when {
                        current.kind == ProviderKind.OpenRouter -> BalanceUiState.Hidden
                        previousBalance != null -> BalanceUiState.Loaded(previousBalance, isRefreshing = false)
                        else -> BalanceUiState.KeyInvalid(e.detail)
                    }
                    previousBalance != null -> BalanceUiState.Loaded(previousBalance, isRefreshing = false)
                    else -> BalanceUiState.Error(e.detail)
                }
            } catch (e: Exception) {
                _balanceState.value = if (previousBalance != null) {
                    BalanceUiState.Loaded(previousBalance, isRefreshing = false)
                } else {
                    BalanceUiState.Error(e.message ?: "Unknown error")
                }
            }
        }
    }

    private fun balanceServiceFor(kind: ProviderKind): BalanceQueryable? {
        val qualifier = when (kind) {
            ProviderKind.OpenRouter -> "balance.openRouter"
            ProviderKind.DeepSeek -> "balance.deepseek"
            ProviderKind.Moonshot -> "balance.moonshot"
            ProviderKind.SiliconFlow -> "balance.siliconFlow"
            else -> return null
        }
        return runCatching { get<BalanceQueryable>(named(qualifier)) }.getOrNull()
    }

    fun deleteProvider(onDeleted: () -> Unit) {
        val current = provider.value ?: return
        if (!canDeleteProvider(current)) return
        viewModelScope.launch {
            try {
                providerRepository.deleteProvider(providerID)
                generationParameterSettingsStore?.removeScopes(providerID = providerID)
                capabilityPreferenceStore?.removeScopes(providerID = providerID)
                localCustomFragmentStore?.removeScopes(providerID = providerID)
                generationParameterPresetStore?.removeScopes(providerID = providerID)
                onDeleted()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.snackbar_provider_delete_failed),
                    ),
                )
            }
        }
    }

    fun toggleModelEnabled(model: AIModel) {
        val current = provider.value ?: return
        val enabled = current.models.any { it.id == model.id }
        val updatedModels = if (enabled) {
            if (current.models.size <= 1) return
            current.models.filter { it.id != model.id }
        } else {
            val promotedModel = model.copy(
                isDefault = current.defaultModel == null || current.models.isEmpty(),
            )
            
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.snackbar_model_added, listOf(model.name)),
                    style = GlobalToastStyle.Success,
                ),
            )
            current.models + promotedModel
        }
        updateModels(current, updatedModels)
    }

    fun enableAllCatalogModels() {
        val current = provider.value ?: return
        
        val resolved = resolvedCatalog.value ?: ProviderCatalogResolver.resolve(current)
        val allCatalogModels = resolved.catalog.map { it.model }
        if (allCatalogModels.isEmpty()) return

        val defaultId = current.defaultModel?.id ?: allCatalogModels.firstOrNull()?.id
        val mergedModels = allCatalogModels.map { it.copy(isDefault = it.id == defaultId) }
        updateModels(current, mergedModels)
    }

    fun disableOptionalModels() {
        val current = provider.value ?: return
        val keeper = current.defaultModel ?: current.models.firstOrNull() ?: return
        current.models.filterNot { it.id == keeper.id }.forEach { removed ->
            generationParameterSettingsStore?.removeScopes(providerID = providerID, modelID = removed.id)
            capabilityPreferenceStore?.removeScopes(providerID = providerID, modelID = removed.id)
            localCustomFragmentStore?.removeScopes(providerID = providerID, modelID = removed.id)
            generationParameterPresetStore?.removeScopes(providerID = providerID, modelID = removed.id)
        }
        updateModels(current, listOf(keeper.copy(isDefault = true)))
    }

    fun setDefaultModel(model: AIModel) {
        val current = provider.value ?: return
        val updated = current.models.map {
            it.copy(isDefault = it.id == model.id)
        }
        updateModels(current, updated)
        
        viewModelScope.launch {
            appPreferencesRepository.setLastUsedModel(current.id, model)
        }
    }

    
    var showGrokReauthorization: Boolean by mutableStateOf(false)

    
    var showOpenAIReauthorization: Boolean by mutableStateOf(false)

    
    val grokSubscriptionAvailability: GrokSubscriptionAvailability
        get() = MetadataClient.grokSubscriptionAvailability()

    
    val openAISubscriptionAvailability: OpenAISubscriptionAvailability
        get() = MetadataClient.openAISubscriptionAvailability()

    fun isSubscriptionProvider(provider: Provider): Boolean =
        provider.authMode == ProviderAuthMode.Subscription

    
    fun canReauthorizeSubscription(provider: Provider): Boolean = when {
        !isSubscriptionProvider(provider) -> false
        provider.kind == ProviderKind.OpenAI ->
            openAISubscriptionAvailability is OpenAISubscriptionAvailability.Available
        else -> grokSubscriptionAvailability is GrokSubscriptionAvailability.Available
    }

    
    fun completeGrokReauthorization(tokens: GrokSubscriptionTokens) {
        showGrokReauthorization = false
        viewModelScope.launch {
            isUpdatingApiKey = true
            try {
                providerRepository.updateGrokSubscriptionCredential(providerID, tokens)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                apiKeyEditError = e.message ?: ""
            } finally {
                isUpdatingApiKey = false
            }
        }
    }

    
    fun completeOpenAIReauthorization(tokens: OpenAISubscriptionTokens) {
        showOpenAIReauthorization = false
        viewModelScope.launch {
            isUpdatingApiKey = true
            try {
                providerRepository.updateOpenAISubscriptionCredential(providerID, tokens)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                apiKeyEditError = e.message ?: ""
            } finally {
                isUpdatingApiKey = false
            }
        }
    }

    fun startEditApiKey() {
        val current = provider.value ?: return
        
        
        
        
        
        if (canReauthorizeSubscription(current)) {
            if (current.kind == ProviderKind.OpenAI) {
                showOpenAIReauthorization = true
            } else {
                showGrokReauthorization = true
            }
            return
        }
        if (!canEditApiKey(current)) return
        editingApiKey = ""
        apiKeyEditError = null
        apiKeyEditErrorRes = null
        relayConnectionTestResult = null
        showApiKeyEditor = true
    }

    fun startEditEndpoint() {
        val current = provider.value ?: return
        if (!canEditEndpoint(current)) return
        selectedEndpointId = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
            .resolveRegionOption(current.kind, current.baseUrlText)?.id
            ?: ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
                .regionOptions(current.kind).firstOrNull()?.id
                    .orEmpty()
        endpointEditError = null
        endpointEditErrorRes = null
        showEndpointEditor = true
    }

    fun saveApiKey() {
        val current = provider.value ?: return
        if (!canEditApiKey(current)) return
        val key = editingApiKey.trim()
        if (key.isBlank()) {
            
            
            if (requiresCredential(current) && !hasStoredKey(current)) {
                apiKeyEditErrorRes = R.string.provider_detail_api_key_required
                apiKeyEditError = null
                return
            }
            apiKeyEditErrorRes = null
            apiKeyEditError = null
            showApiKeyEditor = false
            return
        }
        
        if (isCleartextConnection(current)) {
            apiKeyEditErrorRes = R.string.relay_credentials_cleartext_blocked
            apiKeyEditError = null
            return
        }
        
        if (!ProviderKeyInput.isPrintableAsciiKey(key)) {
            apiKeyEditErrorRes = R.string.provider_api_key_illegal_chars
            apiKeyEditError = null
            return
        }

        viewModelScope.launch {
            isUpdatingApiKey = true
            apiKeyEditError = null
            apiKeyEditErrorRes = null
            try {
                providerRepository.updateApiKey(providerID, key)
                relayConnectionTestResult = null
                showApiKeyEditor = false
            } catch (e: Exception) {
                val uiMessage = localizedRelayFailure(e)
                apiKeyEditError = uiMessage
                if (current.kind == ProviderKind.Relay) {
                    relayConnectionTestResult = RelayConnectionTestResult(
                        isSuccess = false,
                        message = uiMessage,
                        failurePresentation = RelayEditFailurePresenter.present(
                            current.copy(apiKey = key, apiKeyPreview = SecureKeyStore.maskApiKey(key)),
                            e,
                        ),
                    )
                }
            } finally {
                isUpdatingApiKey = false
            }
        }
    }

    fun selectEndpoint(optionId: String) {
        selectedEndpointId = optionId
        endpointEditError = null
        endpointEditErrorRes = null
    }

    fun saveEndpoint() {
        val current = provider.value ?: return
        if (!canEditEndpoint(current)) return
        val option = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
            .regionOptions(current.kind).firstOrNull { it.id == selectedEndpointId }
        if (option == null) {
            endpointEditErrorRes = R.string.provider_detail_endpoint_required
            endpointEditError = null
            return
        }

        viewModelScope.launch {
            isUpdatingEndpoint = true
            endpointEditError = null
            endpointEditErrorRes = null
            try {
                providerRepository.updateBaseUrl(providerID, option.baseURL)
                showEndpointEditor = false
            } catch (e: Exception) {
                endpointEditError = e.message ?: ""
            } finally {
                isUpdatingEndpoint = false
            }
        }
    }

    fun toggleGroup(groupID: String) {
        expandedGroups = if (expandedGroups.contains(groupID)) {
            expandedGroups - groupID
        } else {
            expandedGroups + groupID
        }
    }

    fun filteredCatalogModels(): List<ProviderCatalogGroup> {
        val current = provider.value ?: return emptyList()
        val resolved = resolvedCatalogSnapshot.value
            ?.takeIf { it.providerId == current.id }
            ?.catalog
            ?: ProviderCatalogResolver.resolve(current)
        return buildProviderCatalogGroups(
            provider = current,
            resolvedCatalog = resolved,
            searchQuery = modelSearchQuery,
        )
    }

    
    fun computeCatalogGroups(provider: Provider, searchQuery: String): List<ProviderCatalogGroup> {
        
        val resolved = resolvedCatalogSnapshot.value
            ?.takeIf { it.providerId == provider.id }
            ?.catalog
            ?.takeIf { it.catalog.isNotEmpty() || it.hasManualModels }
            ?: ProviderCatalogResolver.resolve(provider)
        return buildProviderCatalogGroups(
            provider = provider,
            resolvedCatalog = resolved,
            searchQuery = searchQuery,
        )
    }

    
    fun enabledModelsTitle(provider: Provider): Int = when (provider.kind) {
        ProviderKind.Relay, ProviderKind.OpenAI -> R.string.provider_detail_models_title
        else -> R.string.added_models
    }

    
    fun requiresCredential(provider: Provider): Boolean =
        if (provider.kind == ProviderKind.Relay) provider.relayRequested.requiresCredential else true

    
    fun hasStoredKey(provider: Provider): Boolean = hasStoredCredential(provider.apiKey)

    fun isCleartextConnection(provider: Provider): Boolean =
        provider.kind == ProviderKind.Relay && provider.relayRequested.isCleartextConnection

    
    fun canEditApiKey(provider: Provider): Boolean =
        provider.kind.allowsCredentialEditing &&
            (requiresCredential(provider) || hasStoredKey(provider))

    
    fun removeApiKey() {
        val current = provider.value ?: return
        if (!current.kind.allowsCredentialEditing) return
        if (!hasStoredKey(current)) {
            showApiKeyEditor = false
            return
        }
        viewModelScope.launch {
            isUpdatingApiKey = true
            apiKeyEditError = null
            apiKeyEditErrorRes = null
            try {
                if (current.kind == ProviderKind.Relay) {
                    providerRepository.removeRelayApiKey(providerID)
                } else {
                    providerRepository.updateApiKey(providerID, "")
                }
                editingApiKey = ""
                showApiKeyEditor = false
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                apiKeyEditError = e.message ?: ""
            } finally {
                isUpdatingApiKey = false
            }
        }
    }

    fun updateModelSearchQuery(value: String) {
        modelSearchQuery = value
    }

    fun canEditEndpoint(provider: Provider): Boolean =
        canEditApiKey(provider) &&
            ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
                .regionOptions(provider.kind).isNotEmpty()

    fun canAccessAdvancedSettings(provider: Provider): Boolean = provider.kind.allowsAdvancedSettings

    fun canRenameProvider(provider: Provider): Boolean = provider.kind != ProviderKind.OpenAI

    fun canAddManualModel(provider: Provider): Boolean =
        when {
            !provider.kind.allowsManualModelEntry -> false
            provider.kind == ProviderKind.Relay -> true
            else -> !ManualRetainedPruner.isPruningEnabled()
        }

    fun canDeleteProvider(provider: Provider): Boolean = provider.kind.allowsDeletion

    fun canDeleteFreeData(provider: Provider): Boolean = provider.kind == ProviderKind.OpenAI

    fun canReportFreeIssue(provider: Provider): Boolean = provider.kind == ProviderKind.OpenAI

    fun saveRelaySettings(
        provider: Provider,
        relayKind: RelayKind,
        relayRequested: RelayRequestedConfig,
        baseUrlText: String?,
        onSaved: () -> Unit = {},
    ) {
        if (provider.kind != ProviderKind.Relay || isSavingRelaySettings) return
        val dropsCredential = !relayRequested.requiresCredential && hasStoredKey(provider)
        
        
        val normalizedBaseUrl = try {
            RelayEndpointPolicy.requireConfigured(
                baseUrl = baseUrlText,
                securityMode = relayRequested.securityMode,
                credentials = RelayEndpointPolicy.credentialsOf(
                    requested = relayRequested,
                    hasKey = hasStoredKey(provider) && !dropsCredential,
                ),
            )
        } catch (e: ProviderServiceError.InvalidConfiguration) {
            
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(relaySaveBlockedMessageRes(e.detail)),
                    style = GlobalToastStyle.Error,
                ),
            )
            return
        }
        val plan = relayEditPlan(provider, relayKind, relayRequested, normalizedBaseUrl)
        val preparedProvider = ensurePreferredModelInList(provider.copy(
            baseUrlText = normalizedBaseUrl,
            relayKind = relayKind,
            
            
            catalogModels = if (plan.refreshCatalog) emptyList() else provider.catalogModels,
            cachedAvailableModelCount = if (plan.refreshCatalog) null else provider.cachedAvailableModelCount,
            relayRequested = relayRequested.copy(
                resolvedAPIBaseURL = if (plan.refreshCatalog) null else relayRequested.resolvedAPIBaseURL,
            ),
        ), relayRequested.modelID)
        val updatedProvider = if (plan.refreshCatalog) {
            preparedProvider.copy(catalogModels = emptyList(), cachedAvailableModelCount = null)
        } else {
            preparedProvider
        }

        relayEditJob?.cancel()
        pendingRelayEdit = null
        canSaveRelaySettingsUnverified = false
        relayConnectionTestResult = null
        val generation = ++relayEditGeneration
        relayEditJob = viewModelScope.launch {
            isSavingRelaySettings = true
            if (plan.refreshCatalog) relayCatalogTransientState = RelayCatalogUiState.Loading
            try {
                if (!plan.requiresVerification) {
                    providerRepository.updateProvider(updatedProvider)
                    if (generation != relayEditGeneration) return@launch
                    _optimisticProvider.value = updatedProvider
                    onSaved()
                    return@launch
                }
                val outcome = providerRepository.verifyAndPersistRelayEdit(
                    candidate = updatedProvider,
                    refreshCatalog = plan.refreshCatalog,
                    commitGuard = { generation == relayEditGeneration },
                )
                if (generation != relayEditGeneration || outcome.stale) return@launch
                if (outcome.persisted && outcome.verificationSucceeded) {
                    val persisted = outcome.provider ?: updatedProvider
                    _optimisticProvider.value = persisted
                    relayConnectionTestResult = RelayConnectionTestResult(true, "")
                    onSaved()
                    val revision = outcome.persistedRevision
                    if (plan.refreshCatalog && revision != null) {
                        launchRelayCatalogRefreshAfterSave(revision, generation)
                    } else {
                        relayCatalogTransientState = null
                    }
                } else {
                    val failure = outcome.error ?: IllegalStateException(
                        ProviderRepository.RELAY_UNVERIFIED_MESSAGE,
                    )
                    val uiMessage = localizedRelayFailure(failure)
                    pendingRelayEdit = outcome.failureRevision?.let { revision ->
                        PendingRelayEdit(updatedProvider, uiMessage, revision, plan.refreshCatalog)
                    }
                    canSaveRelaySettingsUnverified = pendingRelayEdit != null
                    
                    relayCatalogTransientState = null
                    relayConnectionTestResult = RelayConnectionTestResult(
                        isSuccess = false,
                        message = uiMessage,
                        failurePresentation = RelayEditFailurePresenter.present(updatedProvider, failure),
                    )
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: Exception) {
                if (generation == relayEditGeneration) {
                    val uiMessage = localizedRelayFailure(error)
                    
                    
                    pendingRelayEdit = null
                    canSaveRelaySettingsUnverified = false
                    relayCatalogTransientState = null
                    relayConnectionTestResult = RelayConnectionTestResult(false, uiMessage)
                }
            } finally {
                if (generation == relayEditGeneration) {
                    isSavingRelaySettings = false
                    relayEditJob = null
                }
            }
        }
    }

    
    fun saveRelaySettingsUnverified(onSaved: () -> Unit = {}) {
        val pending = pendingRelayEdit ?: return
        if (isSavingRelaySettings) return
        val generation = ++relayEditGeneration
        relayEditJob = viewModelScope.launch {
            isSavingRelaySettings = true
            try {
                val outcome = providerRepository.persistRelayEditUnverified(
                    candidate = pending.candidate,
                    failureRevision = pending.failureRevision,
                    commitGuard = { generation == relayEditGeneration },
                )
                if (generation != relayEditGeneration) return@launch
                if (outcome.stale) {
                    pendingRelayEdit = null
                    canSaveRelaySettingsUnverified = false
                    return@launch
                }
                if (!outcome.persisted) return@launch
                outcome.provider?.let { _optimisticProvider.value = it }
                pendingRelayEdit = null
                canSaveRelaySettingsUnverified = false
                onSaved()
                val revision = outcome.persistedRevision
                if (pending.refreshCatalog && revision != null) {
                    launchRelayCatalogRefreshAfterSave(revision, generation)
                } else {
                    relayCatalogTransientState = null
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(message = UiText.Resource(R.string.snackbar_provider_save_failed)),
                )
            } finally {
                if (generation == relayEditGeneration) {
                    isSavingRelaySettings = false
                    relayEditJob = null
                }
            }
        }
    }

    
    private fun launchRelayCatalogRefreshAfterSave(
        revision: ProviderRepository.RelayEditRevision,
        editGeneration: Long,
    ) {
        relayCatalogTransientState = RelayCatalogUiState.Loading
        viewModelScope.launch {
            val catalogOutcome = try {
                providerRepository.refreshRelayCatalogOnly(providerID, revision)
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                if (editGeneration == relayEditGeneration) {
                    relayCatalogTransientState = RelayCatalogUiState.Failed
                }
                return@launch
            }
            if (editGeneration != relayEditGeneration) return@launch
            if (catalogOutcome.stale) {
                relayCatalogTransientState = null
                return@launch
            }
            catalogOutcome.provider?.let { _optimisticProvider.value = it }
            relayCatalogTransientState = when {
                !catalogOutcome.catalogSucceeded -> RelayCatalogUiState.Failed
                catalogOutcome.provider?.catalogModels.isNullOrEmpty() -> RelayCatalogUiState.Empty
                else -> RelayCatalogUiState.Available
            }
        }
    }

    
    @androidx.annotation.VisibleForTesting
    internal fun relaySaveBlockedMessageRes(reason: String): Int = when (reason) {
        "cleartext_credentials" -> R.string.relay_credentials_cleartext_blocked
        else -> R.string.relay_setup_invalid_endpoint_message
    }

    fun renameProvider(provider: Provider, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return

        _optimisticProvider.value = provider.copy(customName = trimmed)
        viewModelScope.launch {
            try {
                providerRepository.renameProvider(provider, trimmed)
                delay(300)
                if (_optimisticProvider.value?.id == provider.id) {
                    _optimisticProvider.value = null
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                
                if (_optimisticProvider.value?.id == provider.id) {
                    _optimisticProvider.value = null
                }
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.snackbar_provider_save_failed),
                    ),
                )
            }
        }
    }

    private fun ensurePreferredModelInList(provider: Provider, modelID: String?): Provider {
        val preferredId = modelID?.trim()?.takeIf { it.isNotEmpty() } ?: return provider
        val existing = (provider.models + provider.catalogModels).firstOrNull { it.id == preferredId }
        
        val defaults = ProviderRepository.DEFAULT_MANUAL_MODEL_CAPABILITIES
        val baseModel = existing ?: AIModel(
            id = preferredId,
            name = preferredId,
            capabilities = defaults,
            imageGenProfile = if (ModelCapability.ImageGen in defaults) "default" else null,
            isManual = true,
        )
        fun markOrAppend(models: List<AIModel>): List<AIModel> {
            val withPreferred = if (models.any { it.id == preferredId }) {
                models
            } else {
                models + baseModel
            }
            return withPreferred.map { model -> model.copy(isDefault = model.id == preferredId) }
        }
        return provider.copy(
            models = markOrAppend(provider.models),
            catalogModels = markOrAppend(provider.catalogModels),
        )
    }

    private fun updateModels(current: Provider, models: List<AIModel>) {
        val resolvedDefaultId = models.firstOrNull { it.isDefault }?.id ?: models.firstOrNull()?.id
        val normalized = models.map { model ->
            model.copy(isDefault = resolvedDefaultId != null && model.id == resolvedDefaultId)
        }
        val updatedProvider = current.copy(models = normalized)
        updateProvider(updatedProvider)
    }

    private fun updateProvider(updatedProvider: Provider) {
        
        _optimisticProvider.value = updatedProvider

        viewModelScope.launch {
            try {
                providerRepository.updateProvider(updatedProvider)
                
                delay(300)
                if (_optimisticProvider.value === updatedProvider) {
                    _optimisticProvider.value = null
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                
                
                
                if (_optimisticProvider.value === updatedProvider) {
                    _optimisticProvider.value = null
                }
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.snackbar_provider_save_failed),
                    ),
                )
            }
        }
    }

}
