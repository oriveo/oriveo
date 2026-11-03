package ai.oriveo.community.core.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.data.database.DatabaseHealthProbe
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.ActiveModelSelection
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.UnsupportedParamNoticeBus
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.realtime.RealtimePendingSelection
import ai.oriveo.community.core.voice.realtime.RealtimeSelection
import ai.oriveo.community.core.voice.realtime.realtimeCatalogChanges
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
    private val providerRepository: ProviderRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val skillRepository: SkillRepository,
    private val databaseHealthProbe: DatabaseHealthProbe,
    /** Snapshot of the voice catalog cache (read synchronously; production reads VoiceCatalogClient.state); null = no realtime models recognized. */
    private val voiceCatalog: () -> ai.oriveo.community.core.voice.VoiceCatalog? = { null },
    /** Voice catalog state stream (production reads VoiceCatalogClient.state); null (e.g. unit tests) = no catalog source, nothing is stashed. On arrival / change, re-judges the stashed selection. */
    private val voiceCatalogStates: Flow<VoiceCatalogState?>? = null,
) : ViewModel() {

    private val databaseFlowScope = CoroutineScope(
        viewModelScope.coroutineContext + CoroutineExceptionHandler { _, error ->
            if (databaseHealthProbe.recordEscapedFailure(error)) return@CoroutineExceptionHandler
            Thread.currentThread().let { thread ->
                thread.uncaughtExceptionHandler?.uncaughtException(thread, error)
            }
        },
    )

    val hasCompletedOnboarding: StateFlow<Boolean?> = appPreferencesRepository.hasCompletedOnboarding
        .map<Boolean, Boolean?> { it }
        .stateIn(
            databaseFlowScope,
            SharingStarted.WhileSubscribed(5000),
            appPreferencesRepository.initialOnboardingCompleted,
        )

    val theme: StateFlow<ThemeOption> = appPreferencesRepository.theme
        .stateIn(databaseFlowScope, SharingStarted.WhileSubscribed(5000), ThemeOption.Dark)

    val language: StateFlow<LanguageOption> = appPreferencesRepository.language
        .stateIn(databaseFlowScope, SharingStarted.WhileSubscribed(5000), LanguageOption.System)

    val lastUsedModelRef: StateFlow<LastUsedModelRef?> = appPreferencesRepository.lastUsedModelRef
        .stateIn(databaseFlowScope, SharingStarted.WhileSubscribed(5000), null)

    private val providers = providerRepository.observeAll()
        .stateIn(databaseFlowScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val activeModel: StateFlow<ActiveModelSelection?> = combine(
        providers,
        lastUsedModelRef,
    ) { providerList, lastUsed ->
        resolveActiveModel(providerList, lastUsed)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    init {
        viewModelScope.launch {
            UnsupportedParamNoticeBus.recoveredParams.collect { param ->
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(
                            R.string.generation_parameter_self_healed,
                            listOf(param),
                        ),
                        style = GlobalToastStyle.Warning,
                        durationMs = 5_000,
                    ),
                )
            }
        }
    }

    fun setActiveModel(providerId: String, modelId: String) {
        // Synchronous warm-up override, aligned with HomeViewModel.setActiveModel. Without this line, the provider detail "chat"
        // only writes the new selection to Room asynchronously, while lastUsedModelRef's combine is override ?: stored——
        // an older model picked on the home page / inside a conversation in this process would stick, and the top of a new conversation would keep showing it.
        // Realtime models do not write last-used: when the connection is known and the catalog realtime[] hits, skip the write; when the connection is unknown but the catalog lists this model, judge once the connection arrives.
        val catalog = voiceCatalog()
        // When the catalog is not ready, realtime-ness cannot be judged: stash first, do not prime or write last-used; the subscription re-judges once the catalog arrives.
        if (catalog == null && voiceCatalogStates != null) {
            pendingSelection.stash(providerId, modelId)
            return
        }
        pendingSelection.clear()
        val knownProvider = providers.value.firstOrNull { it.id == providerId }
        if (RealtimeSelection.isRealtime(knownProvider, modelId, catalog)) return
        val deferPrime = knownProvider == null && RealtimeSelection.catalogListsRealtime(modelId, catalog)
        if (!deferPrime) appPreferencesRepository.primeLastUsedModel(providerId, modelId)
        viewModelScope.launch {
            // providers is WhileSubscribed: with no subscriber its value is empty, so read the repository once, otherwise it would write the raw id.
            val provider = knownProvider
                ?: providerRepository.observeAll().first().firstOrNull { it.id == providerId }
            if (RealtimeSelection.isRealtime(provider, modelId, catalog)) return@launch
            if (deferPrime) appPreferencesRepository.primeLastUsedModel(providerId, modelId)
            persistLastUsed(providerId, modelId, provider)
        }
    }

    /** Stash for a selection made while the catalog is not ready: re-judged once both the catalog and the connection arrive (realtime → not written; text → written as last-used). */
    private val pendingSelection = RealtimePendingSelection()

    init {
        // The VM subscribes to the catalog itself: emits only on content change; with a stashed selection, waits until its connection is also in the list before re-judging, regardless of which of catalog / list arrives first.
        viewModelScope.launch {
            val states = voiceCatalogStates ?: return@launch
            states.realtimeCatalogChanges().collectLatest { catalog ->
                val pending = pendingSelection.current ?: return@collectLatest
                if (catalog == null) return@collectLatest
                val provs = providerRepository.observeAll().first { list -> list.any { it.id == pending.providerId } }
                when (val resolution = pendingSelection.resolve(catalog, provs)) {
                    is RealtimePendingSelection.Resolution.Text -> {
                        val (providerId, modelId) = resolution.pending
                        appPreferencesRepository.primeLastUsedModel(providerId, modelId)
                        persistLastUsed(providerId, modelId, provs.firstOrNull { it.id == providerId })
                    }
                    // Neither side recognizes it: do not write last-used, and show that the model is no longer available.
                    is RealtimePendingSelection.Resolution.Gone -> showPendingModelGone(resolution.pending.modelId)
                    is RealtimePendingSelection.Resolution.Realtime, null -> Unit
                }
            }
        }
    }

    private fun showPendingModelGone(modelId: String) {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(R.string.voice_realtime_failure_model_gone, listOf(modelId)),
                style = GlobalToastStyle.Warning,
            ),
        )
    }

    private suspend fun persistLastUsed(providerId: String, modelId: String, provider: Provider?) {
        val selection = ProviderSelectionSnapshot.persistedSelection(provider, modelId)
        if (selection?.model != null) {
            appPreferencesRepository.setLastUsedModel(providerId, selection.model, provider?.kind)
        } else {
            appPreferencesRepository.setLastUsedModel(
                providerId = providerId,
                // Aligned with HomeViewModel: the fallback path also strips the manual- prefix, otherwise the same model
                // picked from the provider detail and from the home picker would write two kinds of ID
                modelId = selection?.storedModelId ?: ModelSelectionUtils.resolvedId(modelId),
            )
        }
    }

    fun markUiReady() {
        viewModelScope.launch { skillRepository.refreshAll() }
    }
}
