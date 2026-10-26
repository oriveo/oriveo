package ai.oriveo.community.feature.providers.detail

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.model.clearingLegacyWebSearch
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
import ai.oriveo.community.core.data.repository.RelayEditMerge
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.isMissingCredentialForNewChat
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.provider.BALANCE_CAPABLE_KINDS
import ai.oriveo.community.core.provider.BalanceQueryable
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.core.provider.ProviderBalanceRepository
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.RelayModelFallback
import org.koin.core.component.KoinComponent
import org.koin.core.component.get
import org.koin.core.qualifier.named
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationParameterPresetStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability
import ai.oriveo.community.core.provider.grok.GrokSubscriptionTokens
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAvailability
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionTokens
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.isCleartextConnection
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.provider.ManualRetainedPruner
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.provider.ProviderKeyInput
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.ResolvedProviderCatalog
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.providers.relay.RelayConnectionTestResult
import ai.oriveo.community.feature.providers.relay.RelayEditFailurePresenter
import ai.oriveo.community.feature.providers.relay.RelayEditSavePolicy
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
import kotlinx.coroutines.flow.onStart
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
 * The single production rule for how much of a Relay edit needs re-verifying. The button label in the UI and the real save path must both consume it,
 * and the two places must not each guess which fields need a network request.
 *
 * Only the address (compared after normalization), the default transport, the authentication mode and connection security count. relayKind is no longer a user option;
 * it is derived from the default transport on save and is not part of the connection identity; the edit page has no model field either, so the model takes no part in the classification.
 */
internal data class RelayEditPlan(
    val requiresVerification: Boolean,
    val refreshCatalog: Boolean,
) {
    companion object {
        fun classify(
            persisted: Provider,
            candidateRequested: RelayRequestedConfig,
            candidateBaseUrl: String?,
        ): RelayEditPlan {
            val persistedRequested = persisted.relayRequested ?: RelayRequestedConfig()
            val transportChanged = persistedRequested.transport != candidateRequested.transport
            val authChanged = persistedRequested.authMode != candidateRequested.authMode
            val securityChanged = persistedRequested.securityMode != candidateRequested.securityMode
            val changed = endpointChanged(persisted, candidateBaseUrl) || transportChanged ||
                authChanged || securityChanged
            return RelayEditPlan(requiresVerification = changed, refreshCatalog = changed)
        }

        /**
         * "Whether the address changed" compares the normalized values on both sides (scheme added, surrounding whitespace and trailing slash removed): differing only in those does not count as a change.
         * The primary button text, whether to send a verification and whether the discovered root address is cleared all use this one criterion.
         */
        fun endpointChanged(persisted: Provider, candidateBaseUrl: String?): Boolean {
            val mode = persisted.relayRequested?.securityMode ?: RelayConnectionSecurityMode.RemoteHttps
            return endpointKey(persisted.baseUrlText, mode) != endpointKey(candidateBaseUrl, mode)
        }

        internal fun endpointKey(raw: String?, mode: RelayConnectionSecurityMode): String =
            RelayEditMerge.endpointKey(raw, mode)

        /**
         * Classification for the edit page: shared by the button text and the save. Only a connection field that the user changed (draft != baseline) and that differs from the current connection
         * counts as a change; a field the user did not change but that was changed elsewhere takes the live value and does not trigger verification.
         */
        fun classifyEdit(
            live: Provider,
            baseline: Provider,
            candidateRequested: RelayRequestedConfig,
            candidateBaseUrl: String?,
        ): RelayEditPlan {
            val baseRequested = baseline.relayRequested ?: RelayRequestedConfig()
            val liveRequested = live.relayRequested ?: RelayRequestedConfig()
            fun <T> effective(field: (RelayRequestedConfig) -> T): T =
                if (field(candidateRequested) != field(baseRequested)) field(candidateRequested) else field(liveRequested)
            val effectiveBaseUrl = if (endpointChanged(baseline, candidateBaseUrl)) candidateBaseUrl else live.baseUrlText
            return classify(
                persisted = live,
                candidateRequested = liveRequested.copy(
                    transport = effective { it.transport },
                    authMode = effective { it.authMode },
                    securityMode = effective { it.securityMode },
                ),
                candidateBaseUrl = effectiveBaseUrl,
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
        val baseline: Provider,
        val uiFailureMessage: String,
        val failureRevision: ProviderRepository.RelayEditRevision,
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

    /** The fallback model of a relay depends on the "last used" model. */
    private val lastUsedModelRef: StateFlow<LastUsedModelRef?> = appPreferencesRepository.lastUsedModelRef
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val lastUsedModelRefSnapshot: LastUsedModelRef?
        get() = appPreferencesRepository.lastUsedModelRefSnapshot ?: lastUsedModelRef.value

    /** Verification sample of a relay: the fallback model, then the first catalog model; an official connection keeps using its default model. */
    fun relaySampleModelID(provider: Provider): String? =
        if (provider.kind == ProviderKind.Relay) {
            RelayModelFallback.verificationSampleModelID(provider, lastUsedModelRefSnapshot)
        } else {
            provider.defaultModel?.id
        }

    /**
     * The model used to start a chat from a connection. The new-chat chain is scoped to this connection:
     * its last-used model, then the catalog default, then the first available one; isDefault is not read.
     * A relay uses the fallback (enabled models only). Returns null when none is available.
     */
    fun startChatModelID(provider: Provider): String? =
        // A missing credential (no key) means a chat cannot start, relay included.
        if (provider.isMissingCredentialForNewChat()) {
            null
        } else if (provider.kind == ProviderKind.Relay) {
            RelayModelFallback.fallbackModel(provider, lastUsedModelRefSnapshot)?.id
        } else {
            resolveActiveModel(
                providers = listOf(provider),
                lastUsedModelRef = lastUsedModelRefSnapshot?.takeIf { it.providerID == provider.id },
            )?.model?.id
        }

    /**
     * Which model the "start chat" action on a model row opens: null (do not start) when the credential
     * is missing (same criterion as [canStartChat]) or the model is unavailable.
     */
    fun modelRowStartChatID(provider: Provider, model: AIModel): String? =
        if (provider.isMissingCredentialForNewChat() || !model.isAvailable) {
            null
        } else {
            model.id
        }

    /** Enabled state of the detail page's "start chat" button: same source as the tap ([startChatModelID]); disabled when every enabled model is retired. */
    fun canStartChat(provider: Provider): Boolean = startChatModelID(provider) != null

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

    /** A reconnect after choosing connection security is in flight (in-progress style; both buttons of the action bar are disabled). */
    var isReconnectingRelaySecurity: Boolean by mutableStateOf(false)
        private set

    /** The detail page "Re-detect" is running: the button shows loading and cannot be tapped again. */
    var isRedetecting: Boolean by mutableStateOf(false)
        private set

    var relayConnectionTestResult: RelayConnectionTestResult? by mutableStateOf(null)
        private set

    /**
     * The "Test capabilities" bottom panel: tapping the button enters the in-progress state, and per-item progress, completion or interruption all stay on the panel; null = no panel.
     * Presentation goes through [RelayCapabilityTestPanelModel.present]; the elapsed time of the running item is refreshed by the UI every 0.1 s based on [runningStartedAtMillis].
     */
    data class RelayCapabilityTestPanelState(
        val model: AIModel,
        val transport: ai.oriveo.community.core.model.RelayTransport,
        val keyName: String?,
        val items: List<ai.oriveo.community.core.provider.relay.RelayCapabilityTestKind>,
        val phase: RelayCapTestPhase,
        val results: List<ai.oriveo.community.core.provider.relay.RelayCapabilityTestItemResult> = emptyList(),
        val running: ai.oriveo.community.core.provider.relay.RelayCapabilityTestKind? = null,
        val runningStartedAtMillis: Long = 0L,
        val written: Boolean = false,
        val stopReason: ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason? = null,
        /** The fragment source of the web item: with no stored fragment the protocol's built-in template (the effective fragment) is probed. */
        val webSource: ai.oriveo.community.core.provider.relay.RelayWebSource =
            ai.oriveo.community.core.provider.relay.RelayWebSource.Saved,
    ) {
        fun panelInput(nowMillis: Long): RelayCapTestPanelInput = RelayCapTestPanelInput(
            transport = transport,
            items = items,
            keyName = keyName,
            phase = phase,
            results = results,
            running = running,
            runningElapsedMs = if (running != null) nowMillis - runningStartedAtMillis else 0L,
            written = written,
            stopReason = stopReason,
            webSource = webSource,
        )
    }

    var relayCapabilityTest: RelayCapabilityTestPanelState? by mutableStateOf(null)
        private set
    private var relayCapabilityTestJob: Job? = null
    private var relaySecurityModeGeneration: Long = 0L
    private var relaySecurityModeJob: kotlinx.coroutines.Job? = null
    private var relayConnectionTestGeneration: Long = 0L
    private var relayConnectionTestJob: kotlinx.coroutines.Job? = null
    private var relayEditGeneration: Long = 0L
    private var relayEditJob: Job? = null
    private var pendingRelayEdit: PendingRelayEdit? = null

    /** The connection when the edit page was opened: saving merges only the fields where the draft != it onto the live record at persist time. */
    private var relayEditBaseline: Provider? = null

    fun beginRelayEdit(provider: Provider) {
        relayEditBaseline = provider
    }

    fun endRelayEdit() {
        relayEditBaseline = null
    }

    var isSavingRelaySettings: Boolean by mutableStateOf(false)
        private set

    var canSaveRelaySettingsUnverified: Boolean by mutableStateOf(false)
        private set

    private var relayCatalogTransientState: RelayCatalogUiState? by mutableStateOf(null)

    /** One-line reason for the single-key catalog fetch failure card (the existing failure classification, in memory for this session); cleared on success and not shown when absent. */
    var relayCatalogFailureDetail: String? by mutableStateOf(null)
        private set

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
        relayRequested: RelayRequestedConfig,
        baseUrlText: String?,
    ): RelayEditPlan = RelayEditPlan.classify(
        persisted = provider,
        candidateRequested = relayRequested,
        candidateBaseUrl = baseUrlText,
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
        // metadataSource is not a Flow. After a 304 the catalog content is unchanged and the
        // deduplicated resolvedCatalog does not emit, so re-read the source on every refresh signal,
        // or the "last synced" banner stays stuck on the cold-start frame.
        metadataRefreshSignal.onStart { emit(Unit) },
    ) { resolved, p, _ ->
        // The source is per provider: with per-provider catalogs each one is fresh or cached on its own.
        val source = p?.let { MetadataClient.metadataSource(it.kind) } ?: MetadataClient.metadataSource
        when {
            p == null -> CatalogViewState.Normal
            p.kind == ProviderKind.Relay -> CatalogViewState.Normal
            // This catalog is still loading: neither offline nor "manual models only"; the refresh
            // signal recomputes once it arrives.
            resolved?.catalogPending == true -> CatalogViewState.Normal
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
                val currentSource = ProviderCredentialResolver.apiKey(p, null) to p.baseUrlText
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
        // Set the flag before launching the coroutine: on rapid taps of the recovery card's "Re-verify" the second tap must be blocked, which cannot depend on when the coroutine starts running.
        isResyncing = true
        viewModelScope.launch {
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

    /**
     * The detail page "Re-detect": calls the domain function [ProviderRepository.redetectRelayModels].
     * When the catalog refresh fails the repository writes [ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE] and does not update the detection time;
     * here it is presented with the existing "connection check failed" toast.
     */
    fun redetectRelayModels() {
        if (isRedetecting) return
        val current = provider.value ?: return
        if (current.kind != ProviderKind.Relay) return
        isRedetecting = true
        viewModelScope.launch {
            try {
                val refreshed = providerRepository.redetectRelayModels(providerID)
                val failure = refreshed?.lastError?.takeIf { it == ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE }
                if (failure != null) emitResyncFailed(failure)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                val providerError = e as? ProviderServiceError
                emitResyncFailed(providerError?.let(::localizedRelayFailure) ?: e.message.orEmpty())
            } finally {
                isRedetecting = false
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
                relayCatalogFailureDetail = outcome.error?.takeIf { !outcome.catalogSucceeded }?.let(::localizedRelayFailure)
                relayCatalogTransientState = when {
                    !outcome.catalogSucceeded -> RelayCatalogUiState.Failed
                    outcome.provider?.catalogModels.isNullOrEmpty() -> RelayCatalogUiState.Empty
                    else -> RelayCatalogUiState.Available
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: Exception) {
                relayCatalogFailureDetail = localizedRelayFailure(error)
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

    /**
     * Test connection tests the draft: unsaved changes are tested too, and the request is built in the same shape as saving;
     * the result is written back to the connection state only when the draft is the same as the stored connection.
     */
    fun testRelayConnection(
        provider: Provider,
        relayRequested: RelayRequestedConfig,
        endpoint: String,
        modelID: String,
    ) {
        if (provider.kind != ProviderKind.Relay || isTestingRelayConnection || isReconnectingRelaySecurity) return
        val trimmedEndpoint = endpoint.trim()
        val trimmedModelID = modelID.trim().ifEmpty { relaySampleModelID(provider).orEmpty() }
        // A stored key is required only for connections that need credentials; an empty key on a local engine with auth=none is a legitimate state and must not be blocked by the connection test
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
        val apiKeySnapshot = ProviderCredentialResolver.apiKey(provider, null)
        // The test request names a model, so the key is taken for that model; what is written back to failureCandidate still uses the connection-level key.
        val requestApiKeySnapshot = ProviderCredentialResolver.apiKey(provider, trimmedModelID)
        val requestedSnapshot = RelayEditSavePolicy.savedRequested(provider, relayRequested, normalizedEndpoint)
            .copy(modelID = trimmedModelID)
        val relayKind = RelayEditSavePolicy.savedRelayKind(requestedSnapshot)
        val isPersistedConnection = isPersistedRelayConnection(
            provider = provider,
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
                        apiKey = requestApiKeySnapshot,
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
                    error = relayFailureError(e),
                )
            } catch (e: Exception) {
                if (generation != relayConnectionTestGeneration) return@launch
                relayConnectionTestResult = RelayConnectionTestResult(
                    isSuccess = false,
                    message = localizedRelayFailure(e),
                    failurePresentation = RelayEditFailurePresenter.present(failureCandidate, e),
                    error = relayFailureError(e),
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
        relayRequested: RelayRequestedConfig,
        normalizedEndpoint: String,
        modelID: String,
    ): Boolean {
        val persistedRequested = provider.relayRequested ?: return false
        // A relay no longer persists modelID: an old value in the database does not count, and the comparison uses the current verification sample.
        val persistedModelID = relaySampleModelID(provider).orEmpty()
        return !RelayEditPlan.endpointChanged(provider, normalizedEndpoint) &&
            persistedModelID == modelID &&
            relayRequestedMatchesPersisted(
                persisted = persistedRequested.copy(modelID = persistedModelID),
                candidate = relayRequested,
            )
    }

    /**
     * The edit page draft changed: invalidate any test and save in flight (a result lands only if the draft is unchanged), but do not interrupt the connection security reconnect,
     * which is an independent, already persisted transaction; interrupting it would leave the connection in the unverified state.
     */
    fun invalidateRelayDraftEvidence() {
        relayConnectionTestGeneration += 1
        relayEditGeneration += 1
        relayConnectionTestJob?.cancel()
        relayConnectionTestJob = null
        relayEditJob?.cancel()
        relayEditJob = null
        isSavingRelaySettings = false
        pendingRelayEdit = null
        canSaveRelaySettingsUnverified = false
        isTestingRelayConnection = false
        if (!isReconnectingRelaySecurity) {
            relayCatalogTransientState = null
            relayConnectionTestResult = null
        }
    }

    /** Any change to an outbound field in the draft invalidates the old probe, and "Connected" must not keep being shown. */
    fun invalidateRelayConnectionTest() {
        relaySecurityModeGeneration += 1
        relayConnectionTestGeneration += 1
        relayEditGeneration += 1
        relaySecurityModeJob?.cancel()
        relaySecurityModeJob = null
        isReconnectingRelaySecurity = false
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
        val effectiveKey = if (cleartext) "" else ProviderCredentialResolver.apiKey(provider, null)
        // The reconnect ping names the default model, so the request key is taken for that model; what is written back to issueProvider still uses the connection-level key.
        val pingKey = if (cleartext) "" else ProviderCredentialResolver.apiKey(provider, relaySampleModelID(provider)?.ifEmpty { null })
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
            isReconnectingRelaySecurity = true
            try {
                if (cleartext && hadStoredKey) {
                    if (generation != relaySecurityModeGeneration) return@launch
                    providerRepository.updateApiKey(providerID, "")
                }
                if (generation != relaySecurityModeGeneration) return@launch
                providerRepository.updateProvider(issueProvider)
                if (generation != relaySecurityModeGeneration) return@launch

                val modelID = relaySampleModelID(provider).orEmpty()
                val pingFailure = runCatching {
                    providerRepository.pingRelayConnection(
                        apiKey = pingKey,
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
                    // When the reconnect ends only the status is written, onto the connection that is in the database right now; other fields are left alone (a save made in the meantime is not overwritten by an old snapshot).
                    val detail = localizedRelayFailure(pingFailure)
                    finalProvider = (latestPersistedProvider() ?: finalProvider).copy(
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
                    error = (pingFailure ?: catalogOutcome.error)?.let(::relayFailureError),
                )
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: Exception) {
                if (generation == relaySecurityModeGeneration) {
                    val detail = localizedRelayFailure(error)
                    val failed = (latestPersistedProvider() ?: issueProvider).copy(
                        status = ProviderConnectionState.Issue(detail),
                        lastError = detail,
                    )
                    runCatching { providerRepository.updateProvider(failed) }
                    _optimisticProvider.value = failed
                    relayConnectionTestResult = RelayConnectionTestResult(false, detail, error = relayFailureError(error))
                }
            } finally {
                if (generation == relaySecurityModeGeneration) {
                    isReconnectingRelaySecurity = false
                    relaySecurityModeJob = null
                }
            }
        }
    }

    private suspend fun latestPersistedProvider(): Provider? =
        runCatching { providerRepository.getById(providerID) }.getOrNull()

    /** The OriveoError of the failure card: the same exception goes through ErrorMapper (title / severity come from the same source as iOS); null when no Context is available. */
    private fun relayFailureError(error: Throwable): OriveoError? = runCatching {
        val exception = error as? Exception ?: return null
        ErrorMapper.map(exception, get<android.content.Context>())
    }.getOrNull()

    /** The failure card "Close": clears the failure state (iOS RelayEditView `saveError = nil`). */
    fun clearRelayFailure() {
        if (relayConnectionTestResult?.isSuccess == false) relayConnectionTestResult = null
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
        val apiKey = ProviderCredentialResolver.apiKey(current, null)
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
                    ?: requireNotNull(service).fetchBalance(
                        apiKey,
                        ai.oriveo.community.core.provider.transport.OfficialEndpointSource.effectiveBaseUrlText(current),
                    )
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
        // A relay matches by the literal ID: only this one is disabled, and a dated snapshot / another model with the same canonical form is not affected.
        fun isSame(other: AIModel) = if (current.kind == ProviderKind.Relay) {
            ModelSelectionUtils.modelsShareSameRemoteModel(other, model, current.kind)
        } else {
            other.id == model.id
        }
        val enabled = current.models.any(::isSame)
        val updatedModels = if (enabled) {
            if (current.models.size <= 1) return
            val remaining = current.models.filterNot(::isSame)
            current.models.filter(::isSame).forEach { removed -> removeModelPreferenceScopes(current, removed, remaining) }
            remaining
        } else {
            // A multi-key relay binds one key by the same rule as the model picker / add all; everything else stays as is.
            val promotedModel = RelayKeyBinding.withBinding(
                current,
                model.copy(
                    isDefault = current.kind != ProviderKind.Relay &&
                        (current.defaultModel == null || current.models.isEmpty()),
                ),
            )

            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.snackbar_model_added, listOf(model.name)),
                    style = GlobalToastStyle.Success,
                ),
            )
            current.models + promotedModel
        }
        // Only a single enable lazily verifies this model: persist the enablement first, then probe; the probe result is written back by the repository itself.
        updateModels(current, updatedModels, afterPersist = if (enabled || current.kind != ProviderKind.Relay) null else {
            { providerRepository.probeEnabledRelayModel(current.id, model.id) }
        })
    }

    /**
     * The model library group "Add all": only append the entries of [modelIDs] that are not enabled yet and exist in the catalog;
     * keys are bound by the same rule as a single enable, the connection is written back only once, with no probing and no protocol written. Returns the number added; a notice is shown only if something was added.
     */
    fun enableRelayCatalogModels(modelIDs: List<String>): Int {
        val current = provider.value ?: return 0
        var next = current
        val added = mutableListOf<AIModel>()
        for (id in modelIDs) {
            if (next.models.any { it.id == id }) continue
            val entry = current.catalogModels.firstOrNull { it.id == id } ?: continue
            val bound = RelayKeyBinding.withBinding(next, entry.copy(isDefault = false))
            added += bound
            next = next.copy(models = next.models + bound)
        }
        if (added.isEmpty()) return 0
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.PluralResource(R.plurals.relay_catalog_added_models, added.size),
                style = GlobalToastStyle.Success,
            ),
        )
        updateModels(current, next.models)
        return added.size
    }

    fun disableOptionalModels() {
        val current = provider.value ?: return
        val keeper = current.defaultModel ?: current.models.firstOrNull() ?: return
        current.models.filterNot { it.id == keeper.id }.forEach { removed ->
            removeModelPreferenceScopes(current, removed, remaining = listOf(keeper))
        }
        updateModels(current, listOf(keeper.copy(isDefault = current.kind != ProviderKind.Relay)))
    }

    /**
     * Disabling a model deletes its parameter / capability preference keys. Relay: delete the literal key; a legacy canonical key is deleted only when no enabled model on that connection has
     * a canonical form (or literal ID) equal to it, otherwise it would delete an old record that another snapshot reads back. Official providers still delete by model.id.
     */
    private fun removeModelPreferenceScopes(provider: Provider, removed: AIModel, remaining: List<AIModel>) {
        val keys = linkedSetOf(removed.id)
        if (provider.kind == ProviderKind.Relay) {
            keys += ModelSelectionUtils.preferredStoredModelIdentifier(removed, provider.kind)
            val canonical = removed.canonicalModelId?.trim().orEmpty()
            val stillUsed = remaining.any { other ->
                other.canonicalModelId?.trim().equals(canonical, ignoreCase = true) ||
                    ModelSelectionUtils.literalKey(other.id) == canonical.lowercase()
            }
            if (canonical.isNotEmpty() && !stillUsed) keys += canonical
        }
        keys.forEach { key ->
            generationParameterSettingsStore?.removeScopes(providerID = providerID, modelID = key)
            capabilityPreferenceStore?.removeScopes(providerID = providerID, modelID = key)
            localCustomFragmentStore?.removeScopes(providerID = providerID, modelID = key)
            generationParameterPresetStore?.removeScopes(providerID = providerID, modelID = key)
        }
    }

    /** Monotonic clock (milliseconds) for the panel elapsed time; the UI refresh timer uses the same one. */
    fun relayCapabilityTestClockMillis(): Long = System.nanoTime() / 1_000_000L

    /**
     * Executed only when the user taps "Test capabilities" on the "Model > Advanced" page and never triggered automatically: opening the panel means in progress,
     * [transport] is the model's currently effective protocol (the protocol chip), and [keyName] is the key bound when there are two or more keys (pass null for a single key).
     */
    fun requestRelayCapabilityTest(
        model: AIModel,
        transport: ai.oriveo.community.core.model.RelayTransport,
        keyName: String?,
    ) {
        if (relayCapabilityTest?.phase == RelayCapTestPhase.Running) return
        // The first frame already lists the web search items by the same criterion as the orchestration, so the footer tells the truth before any request is sent.
        // With no stored fragment the web item is tested temporarily with the protocol's built-in template; the in-progress subtitle follows the source.
        val webSource = provider.value?.let { ai.oriveo.community.core.provider.relay.RelayCapabilityTest.webSource(it, model) }
        val items = ai.oriveo.community.core.provider.relay.RelayCapabilityTest.plannedKinds(model.relayCapabilityOverrides, webSource != null)
        relayCapabilityTest = RelayCapabilityTestPanelState(
            model = model,
            transport = transport,
            keyName = keyName,
            items = items,
            phase = RelayCapTestPhase.Running,
            running = items.first(),
            runningStartedAtMillis = relayCapabilityTestClockMillis(),
            webSource = webSource ?: ai.oriveo.community.core.provider.relay.RelayWebSource.Saved,
        )
        relayCapabilityTestJob = viewModelScope.launch {
            val run = try {
                providerRepository.runRelayCapabilityTest(providerID, model.id, onProgress = { progress ->
                    val current = relayCapabilityTest ?: return@runRelayCapabilityTest
                    if (current.phase != RelayCapTestPhase.Running) return@runRelayCapabilityTest
                    relayCapabilityTest = current.copy(
                        items = progress.planned,
                        results = progress.results,
                        running = progress.running,
                        runningStartedAtMillis = if (progress.running != null && progress.running != current.running) {
                            relayCapabilityTestClockMillis()
                        } else {
                            current.runningStartedAtMillis
                        },
                    )
                })
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
            val current = relayCapabilityTest
            if (current != null && current.phase == RelayCapTestPhase.Running) {
                relayCapabilityTest = if (run == null) {
                    // The orchestration itself failed (reading the database / reading keys): this can only happen before the write-back is persisted (a synchronous dispatch error after persisting has been swallowed by the repository
                    // and written is returned as usual), so it is always reported as an interruption meaning "this model can no longer be tested" and is never dismissed silently.
                    current.copy(
                        phase = RelayCapTestPhase.Stopped,
                        running = null,
                        stopReason = ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Unavailable,
                    )
                } else {
                    current.copy(
                        items = run.planned.ifEmpty { current.items },
                        results = run.items,
                        running = null,
                        phase = if (run.stopReason != null) RelayCapTestPhase.Stopped else RelayCapTestPhase.Completed,
                        written = run.written,
                        stopReason = run.stopReason,
                        webSource = run.webSource ?: current.webSource,
                    )
                }
            }
            relayCapabilityTestJob = null
        }
    }

    /** Panel "Cancel": stops requests in flight; the panel stays on "Interrupted: you cancelled the test", completed items are kept and nothing is written for the rest. */
    fun cancelRelayCapabilityTest() {
        val current = relayCapabilityTest ?: return
        if (current.phase != RelayCapTestPhase.Running) return
        relayCapabilityTestJob?.cancel()
        relayCapabilityTestJob = null
        relayCapabilityTest = current.copy(
            phase = RelayCapTestPhase.Stopped,
            running = null,
            stopReason = ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Cancelled,
        )
    }

    /** Panel "Done" / swipe away: it cannot be closed while running (cancel is the only way). */
    fun dismissRelayCapabilityTest() {
        if (relayCapabilityTest?.phase == RelayCapTestPhase.Running) return
        relayCapabilityTest = null
    }

    // -- The "Model > Advanced" page --

    /** Single-protocol probe result of this page, in memory only; invalidated when leaving the page or switching protocol. */
    var relayAdvancedProbe: RelayAdvancedProbe? by mutableStateOf(null)
        private set
    private var relayAdvancedProbeJob: Job? = null

    /** Choose a protocol (null = Auto): write or clear the user value first, then run one 1-token probe for the chosen protocol; the result is displayed only and not written. */
    fun setRelayModelTransport(model: AIModel, transport: ai.oriveo.community.core.model.RelayTransport?) {
        relayAdvancedProbeJob?.cancel()
        relayAdvancedProbe = transport?.let { RelayAdvancedProbe(it, RelayAdvancedProbe.State.Running) }
        relayAdvancedProbeJob = viewModelScope.launch {
            try {
                providerRepository.setRelayModelTransport(providerID, model.id, transport)
                if (transport == null) return@launch
                val passed = providerRepository.probeRelayModelTransportOnce(providerID, model.id, transport)
                relayAdvancedProbe = passed?.let {
                    RelayAdvancedProbe(transport, if (it) RelayAdvancedProbe.State.Passed else RelayAdvancedProbe.State.Failed)
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                // Persist or probe failure: do not show a probe result, and the protocol row shows the value in the database.
                relayAdvancedProbe = null
            }
        }
    }

    fun clearRelayAdvancedProbe() {
        relayAdvancedProbeJob?.cancel()
        relayAdvancedProbeJob = null
        relayAdvancedProbe = null
    }

    fun setRelayCapabilityOverride(model: AIModel, capability: RelayAdvancedCapability, value: Boolean?) {
        launchRelayAdvancedWrite { providerRepository.setRelayCapabilityOverride(providerID, model.id, capability, value) }
    }

    fun setRelayReasoningLevels(model: AIModel, levels: List<String>?) {
        launchRelayAdvancedWrite { providerRepository.setRelayReasoningLevels(providerID, model.id, levels) }
    }

    fun restoreRelayModelAutomatic(model: AIModel) {
        clearRelayAdvancedProbe()
        launchRelayAdvancedWrite { providerRepository.restoreRelayModelAutomatic(providerID, model.id) }
    }

    private fun launchRelayAdvancedWrite(write: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                write()
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                // When persisting fails the page shows the old value from the database, and the user can retry.
            }
        }
    }

    fun setDefaultModel(model: AIModel) {
        val current = provider.value ?: return
        // Relay / local have no default model and the entry point has been removed; reject here as a safety net.
        if (current.kind == ProviderKind.Relay) return
        val updated = current.models.map {
            it.copy(isDefault = it.id == model.id)
        }
        updateModels(current, updated)

        viewModelScope.launch {
            appPreferencesRepository.setLastUsedModel(current.id, model, current.kind)
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

    /** Input values of the setup fields in the detail page address editor; prefilled from the stored setupValues when the editor opens. */
    var endpointSetupValues: Map<String, String> by mutableStateOf(emptyMap())
        private set

    /** The fields the user must fill for the selected address template; empty for a region without placeholders, in which case the UI shows no input slot. */
    val endpointSetupFieldIds: List<String>
        get() {
            val current = provider.value ?: return emptyList()
            val option = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
                .detailRegionOptions(current.kind).firstOrNull { it.id == selectedEndpointId } ?: return emptyList()
            return ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver.current()
                .setupFieldIds(current.kind, option)
        }

    /** Saving is possible only when a region is chosen and every field the template needs holds a valid value (a single DNS label, validated by the same function as the setup page). */
    val canSaveEndpoint: Boolean
        get() = selectedEndpointId.isNotBlank() && endpointSetupFieldIds.all {
            OfficialEndpointSource.normalizeSetupValue(endpointSetupValues[it]) != null
        }

    fun updateEndpointSetupField(id: String, value: String) {
        endpointSetupValues = endpointSetupValues + (id to value)
    }

    fun startEditEndpoint() {
        val current = provider.value ?: return
        if (!canEditEndpoint(current)) return
        // What was already stored by region source (including address templates and addresses moved by metadata) trusts the source directly, using the same function as the detail page display.
        selectedEndpointId = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
            .resolveRegionOption(current.kind, current.baseUrlText, current.endpointSource)?.id
            ?: ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
                .detailRegionOptions(current.kind).firstOrNull()?.id
                    .orEmpty()
        endpointSetupValues = current.setupValues.orEmpty()
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
                        error = relayFailureError(e),
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
        // The chosen region is the one the stored address belongs to (source first): do not write back, and the stored address stays verbatim (it may not be among the options, or may be written differently from an option).
        val stored = ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver.current()
            .exactRegionOption(current.kind, current.baseUrlText, current.endpointSource)
        if (stored != null && stored.id == selectedEndpointId) {
            endpointEditError = null
            endpointEditErrorRes = null
            showEndpointEditor = false
            return
        }
        val option = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
            .detailRegionOptions(current.kind).firstOrNull { it.id == selectedEndpointId }
        if (option == null) {
            endpointEditErrorRes = R.string.provider_detail_endpoint_required
            endpointEditError = null
            return
        }
        // Address template: fill in the literal address with valid values and write the address, the region source and the values in one go; non-template entries still write only the address.
        val fieldIds = ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver.current()
            .setupFieldIds(current.kind, option)
        val setupValues = if (fieldIds.isEmpty()) {
            null
        } else {
            fieldIds.associateWith { id ->
                OfficialEndpointSource.normalizeSetupValue(endpointSetupValues[id]) ?: return
            }
        }
        val baseUrl = if (setupValues == null) option.baseURL else OfficialEndpointSource.fill(option.baseURL, setupValues) ?: return
        val endpointSource = setupValues?.let { OfficialEndpointSource.region(option.id) }

        viewModelScope.launch {
            isUpdatingEndpoint = true
            endpointEditError = null
            endpointEditErrorRes = null
            try {
                providerRepository.updateBaseUrl(providerID, baseUrl, endpointSource, setupValues)
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
        ProviderKind.Relay -> R.string.provider_detail_models_title
        else -> R.string.added_models
    }

    fun requiresCredential(provider: Provider): Boolean =
        if (provider.kind == ProviderKind.Relay) provider.relayRequested.requiresCredential else true

    /** Existence counts only the real key loaded from the key store (Provider.apiKey), not the preview. */
    fun hasStoredKey(provider: Provider): Boolean = hasStoredCredential(ProviderCredentialResolver.apiKey(provider, null))

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

    /**
     * The picker display and the repository save use the same catalog criterion: the catalog shows at least one region option.
     * Once the server delivers regions for Z.ai, the picker appears and saving persists as well, no longer blocked by the built-in ProviderKind table.
     */
    fun canEditEndpoint(provider: Provider): Boolean {
        val catalog = ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver.current()
        return canEditApiKey(provider) &&
            catalog.usesConfigurableBaseUrl(provider.kind) &&
            catalog.regionOptions(provider.kind).isNotEmpty()
    }

    fun canAccessAdvancedSettings(provider: Provider): Boolean = provider.kind.allowsAdvancedSettings

    fun canAddManualModel(provider: Provider): Boolean =
        when {
            !provider.kind.allowsManualModelEntry -> false
            provider.kind == ProviderKind.Relay -> true
            else -> !ManualRetainedPruner.isPruningEnabled()
        }

    fun canDeleteProvider(provider: Provider): Boolean = provider.kind.allowsDeletion

    fun saveRelaySettings(
        provider: Provider,
        relayRequested: RelayRequestedConfig,
        baseUrlText: String?,
        onSaved: () -> Unit = {},
    ) {
        // Not accepted while a reconnect is in flight: when the reconnect ends it writes back to the connection.
        if (provider.kind != ProviderKind.Relay || isSavingRelaySettings || isReconnectingRelaySecurity) return
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
        // The candidate is built from the baseline + the draft, and only fields where the candidate != the baseline were changed by the user; if the edit page was never opened (a direct call) the baseline is the current connection.
        val baseline = relayEditBaseline?.takeIf { it.id == provider.id } ?: provider
        // The address is compared after normalization: differing only in scheme / trailing slash does not count as a user change, and the baseline text is kept so that an address changed by sync is not overwritten.
        val editedBaseUrl = if (RelayEditPlan.endpointChanged(baseline, normalizedBaseUrl)) normalizedBaseUrl else baseline.baseUrlText
        // The saved shape always goes through RelayEditSavePolicy: relayKind is derived from the protocol, the reasoning effort is cleared, and the Codex identity and the remaining fields stay as they are.
        val savedRequested = RelayEditSavePolicy.savedRequested(baseline, relayRequested, normalizedBaseUrl)
        val edited = ensurePreferredModelInList(baseline.copy(
            baseUrlText = editedBaseUrl,
            relayKind = RelayEditSavePolicy.savedRelayKind(savedRequested),
            relayRequested = savedRequested,
        ), savedRequested.modelID)
        // Whether to verify uses the same criterion as the button text: a field the user did not change but that was changed elsewhere does not trigger verification.
        // Whether the catalog is cleared and whether it is refreshed after saving is decided by the repository at persist time from "merged vs live record" (RelayEditOutcome.catalogInvalidated).
        val plan = RelayEditPlan.classifyEdit(provider, baseline, relayRequested, normalizedBaseUrl)
        val updatedProvider = edited

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
                    val outcome = providerRepository.persistRelayEditWithoutVerification(
                        candidate = updatedProvider,
                        baseline = baseline,
                        commitGuard = { generation == relayEditGeneration },
                    )
                    // Only two kinds of stale remain: the draft was changed again while in flight, or the connection was deleted; neither closes the page.
                    if (generation != relayEditGeneration || !outcome.persisted) return@launch
                    _optimisticProvider.value = outcome.provider ?: updatedProvider
                    onSaved()
                    val revision = outcome.persistedRevision
                    if (outcome.catalogInvalidated && revision != null) {
                        launchRelayCatalogRefreshAfterSave(revision, generation)
                    }
                    return@launch
                }
                val outcome = providerRepository.verifyAndPersistRelayEdit(
                    candidate = updatedProvider,
                    refreshCatalog = plan.refreshCatalog,
                    commitGuard = { generation == relayEditGeneration },
                    baseline = baseline,
                )
                if (generation != relayEditGeneration || outcome.stale) return@launch
                if (outcome.persisted) {
                    val persisted = outcome.provider ?: updatedProvider
                    _optimisticProvider.value = persisted
                    // During verification the verification-related fields of the connection were changed elsewhere twice: it was persisted according to the merge but the verification state is not written, and the page closes as usual.
                    if (outcome.verificationSucceeded) {
                        relayConnectionTestResult = RelayConnectionTestResult(true, "")
                    }
                    onSaved()
                    val revision = outcome.persistedRevision
                    if (outcome.catalogInvalidated && revision != null) {
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
                        PendingRelayEdit(updatedProvider, baseline, uiMessage, revision)
                    }
                    canSaveRelaySettingsUnverified = pendingRelayEdit != null

                    relayCatalogTransientState = null
                    relayConnectionTestResult = RelayConnectionTestResult(
                        isSuccess = false,
                        message = uiMessage,
                        failurePresentation = RelayEditFailurePresenter.present(updatedProvider, failure),
                        error = relayFailureError(failure),
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
                    relayConnectionTestResult = RelayConnectionTestResult(false, uiMessage, error = relayFailureError(error))
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
                    baseline = pending.baseline,
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
                if (outcome.catalogInvalidated && revision != null) {
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
            } catch (error: Exception) {
                if (editGeneration == relayEditGeneration) {
                    relayCatalogFailureDetail = localizedRelayFailure(error)
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
            relayCatalogFailureDetail = catalogOutcome.error?.takeIf { !catalogOutcome.catalogSucceeded }?.let(::localizedRelayFailure)
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

    // -- Keys page: all writes go through the key operations; after adding / replacing a key the repository re-fetches the catalog of that key only --

    /** A new key id is a random UUID: it serves only as the local binding primary key and is neither displayed nor part of the connection identity comparison. */
    fun addRelayKey(name: String?, secret: String) {
        if (secret.isBlank()) return
        runRelayKeysPageOperation(RelayKeyOperation.Add(java.util.UUID.randomUUID().toString(), name, secret))
    }

    fun replaceRelayKeySecret(keyID: String, secret: String) {
        if (secret.isBlank()) return
        runRelayKeysPageOperation(RelayKeyOperation.ReplaceSecret(keyID, secret))
    }

    /** In-flight work of the keys page (counted per key) and the post-operation notices; the page renders strictly from it. */
    var relayKeysPageState: RelayKeysPageState by mutableStateOf(RelayKeysPageState())
        private set

    /** Web search fragments live in local storage, not on the Provider; after saving, this lets the detail page "Web search" row re-read its state. */
    var relayWebFragmentsRevision: Int by mutableStateOf(0)
        private set

    /**
     * Saving the web search settings page: write the whole set to local storage (an empty section is deleted), then clear the two legacy fields through the decode point and persist the connection.
     */
    fun saveRelayWebFragments(
        current: Provider,
        fragments: Map<ai.oriveo.community.core.model.RelayTransport, kotlinx.serialization.json.JsonObject>,
        store: ai.oriveo.community.core.provider.relay.RelayWebFragmentStore =
            ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.shared,
    ) {
        val requested = current.relayRequested ?: return
        // For a protocol whose fragment hash changed, the tested web result of its first model is invalidated.
        val hash = ai.oriveo.community.core.provider.relay.RelayWebProbe::fragmentHash
        val before = store.effective(current).mapValues { hash(it.value) }
        val after = fragments.mapKeys { it.key.value }.mapValues { hash(it.value) }
        val changed = (before.keys + after.keys).filterTo(mutableSetOf()) { before[it] != after[it] }
        store.replace(current.id, fragments)
        relayWebFragmentsRevision += 1
        val cleared = requested.clearingLegacyWebSearch()
        // A successful save = one automatic probe event; it runs serially in the repository scope and is not cancelled when the page closes. When legacy fields are cleared it triggers only after persisting, so that the overwrite write-back is not covered by an old snapshot.
        val trigger: suspend () -> Unit = { providerRepository.relayWebFragmentsSaved(current.id, changed) }
        if (cleared != requested) {
            updateProvider(current.copy(relayRequested = cleared), afterPersist = trigger)
        } else {
            providerRepository.relayWebFragmentsSaved(current.id, changed)
        }
    }

    /**
     * The web search settings page "Save": returns false if any section is filled in wrongly, writing neither storage nor the database;
     * otherwise same as [saveRelayWebFragments] (empty sections are deleted, and the connection is persisted once with the legacy web search fields cleared).
     */
    fun saveRelayWebSearch(
        current: Provider,
        texts: Map<ai.oriveo.community.core.model.RelayTransport, String>,
        store: ai.oriveo.community.core.provider.relay.RelayWebFragmentStore =
            ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.shared,
    ): Boolean {
        val plan = RelayWebSearchPageModel.plan(texts) ?: return false
        saveRelayWebFragments(current, plan, store)
        return true
    }

    /** The web search probe records changed (a re-test finished): the rejected section re-reads the records accordingly. */
    var relayWebProbeRevision: Int by mutableStateOf(0)
        private set

    /** The model being re-tested; only one runs at a time. */
    var relayWebRetestingModelID: String? by mutableStateOf(null)
        private set

    /**
     * The web search settings page rejected section "Test again": goes through the repository's manual web search probe (stored fragments, not entered into the automatic history),
     * and the result is written to the records and the overlay as usual. If one is already running it is not accepted and false is returned.
     */
    fun retestRelayWebModel(modelID: String): Boolean {
        if (relayWebRetestingModelID != null) return false
        relayWebRetestingModelID = modelID
        viewModelScope.launch {
            try {
                providerRepository.runRelayWebProbe(providerID, modelID)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                // Reading / writing back failed: the records are unchanged, the row stays, and it can be tapped again.
            } finally {
                relayWebRetestingModelID = null
                relayWebProbeRevision += 1
            }
        }
        return true
    }

    fun renameRelayKey(keyID: String, name: String?) =
        runRelayKeysPageOperation(RelayKeyOperation.Rename(keyID, name))

    fun moveRelayKey(keyID: String, toIndex: Int) =
        runRelayKeysPageOperation(RelayKeyOperation.Move(keyID, toIndex))

    fun deleteRelayKey(keyID: String) =
        runRelayKeysPageOperation(RelayKeyOperation.Delete(keyID))

    /** Key section / rebind on the Advanced page: rebinding clears this session's unreachable state for the model, and with no protocol it lazily verifies as when enabling. */
    fun rebindRelayModelKey(model: AIModel, keyID: String) =
        runRelayKeyOperation { providerRepository.rebindRelayModelKey(providerID, model.id, keyID) }

    /** Model library key status strip "Retry": re-fetch the catalog of this one key only. */
    fun retryRelayKeyCatalog(keyID: String) =
        runRelayKeyOperation { providerRepository.refreshRelayKeyCatalog(providerID, keyID) }

    /**
     * Write operations of the keys page: at begin, the previous round of notices is withdrawn and the key is marked as fetching, and the outcome is left to the page state, which appends notices one by one (accepted but fetch failed /
     * interrupted / not accepted), with no global toast any more; the UI refresh is the same as [runRelayKeyOperation].
     */
    private fun runRelayKeysPageOperation(operation: RelayKeyOperation) {
        // Adding a key re-fetches all of them: every key shows as fetching.
        val fetching = operation.fetchingKeyIDs(provider.value)
        relayKeysPageState = relayKeysPageState.begin(operation, fetching)
        viewModelScope.launch {
            val outcome = try {
                applyRelayKeyOperation(providerRepository, providerID, operation)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                RelayKeyOperationOutcome(accepted = false, connection = null, fetchedKeyID = operation.fetchedKeyID)
            }
            relayKeysPageState = relayKeysPageState.finish(outcome, fetching)
            val written = outcome.connection
            _optimisticProvider.value = written
            delay(300)
            if (_optimisticProvider.value === written) _optimisticProvider.value = null
        }
    }

    /**
     * Refresh the UI with the written-back connection; when no written-back object is available (rejected / in flight expired), clear the optimistic value and let the real value in the database speak.
     * A catalog fetch failure does not count as a failure: the status word of that key shows it truthfully. Only a thrown error is presented with the existing "save failed" toast.
     */
    private fun runRelayKeyOperation(operation: suspend () -> Provider?) {
        viewModelScope.launch {
            try {
                val written = operation()
                _optimisticProvider.value = written
                // Same policy as updateProvider: give the Room Flow time before clearing the optimistic value, so that the protocol, relayDeniedKeyID and key states
                // written back afterwards by lazy verification / chat can reach the detail page (an optimistic value left hanging would cover them forever).
                delay(300)
                if (_optimisticProvider.value === written) _optimisticProvider.value = null
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                _optimisticProvider.value = null
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(message = UiText.Resource(R.string.snackbar_provider_save_failed)),
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
            // A relay marks no default: just make sure the chosen model is in the list.
            if (provider.kind == ProviderKind.Relay) return withPreferred.map { it.copy(isDefault = false) }
            return withPreferred.map { model -> model.copy(isDefault = model.id == preferredId) }
        }
        return provider.copy(
            models = markOrAppend(provider.models),
            catalogModels = markOrAppend(provider.catalogModels),
        )
    }

    private fun updateModels(
        current: Provider,
        models: List<AIModel>,
        afterPersist: (suspend () -> Unit)? = null,
    ) {
        val resolvedDefaultId = models.firstOrNull { it.isDefault }?.id ?: models.firstOrNull()?.id
        val normalized = models.map { model ->
            model.copy(
                isDefault = current.kind != ProviderKind.Relay &&
                    resolvedDefaultId != null && model.id == resolvedDefaultId,
            )
        }
        val updatedProvider = current.copy(models = normalized)
        updateProvider(updatedProvider, afterPersist)
    }

    /** [afterPersist]: runs in a separate coroutine after the write succeeds; a failure does not roll back this write and does not show a write-failure notice. */
    private fun updateProvider(updatedProvider: Provider, afterPersist: (suspend () -> Unit)? = null) {
        // Optimistic update: the UI reflects the change immediately
        _optimisticProvider.value = updatedProvider

        viewModelScope.launch {
            try {
                providerRepository.updateProvider(updatedProvider)
                afterPersist?.let { action -> viewModelScope.launch { action() } }
                // Clear the optimistic state with a delay after the DB write, to give the Room Flow time to emit the new value
                delay(300)
                if (_optimisticProvider.value === updatedProvider) {
                    _optimisticProvider.value = null
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                // DB write failed: roll back the optimistic state so the UI returns to the real Room value, and notify the user
                // Trigger paths: toggleModelEnabled / setDefaultModel / enableRelayCatalogModels /
                //          disableOptionalModels / saveRelaySettings all go through here
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
