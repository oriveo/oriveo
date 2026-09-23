package ai.oriveo.community.feature.providers

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationParameterPresetStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.provider.BALANCE_CAPABLE_KINDS
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.core.provider.ProviderBalanceRepository
import ai.oriveo.community.core.usage.CostSummaryCalculator
import ai.oriveo.community.core.usage.MonthlyCostSummary
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class ProvidersViewModel(
    private val providerRepository: ProviderRepository,
    private val conversationRepository: ConversationRepository,
    private val metadataRefreshEventBus: MetadataRefreshEventBus,
    private val providerBalanceRepository: ProviderBalanceRepository? = null,
    private val defaultDispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val generationParameterSettingsStore: GenerationParameterSettingsStore? = null,
    private val capabilityPreferenceStore: ai.oriveo.community.core.model.CapabilityPreferenceStore? = null,
    private val localCustomFragmentStore: LocalCapabilityCustomFragmentStore? = null,
    private val generationParameterPresetStore: GenerationParameterPresetStore? = null,
) : ViewModel() {
    private var providerBalancesRefreshGeneration: Long = 0L

    val providers: StateFlow<List<Provider>> = providerRepository.observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _providerBalances = MutableStateFlow<Map<String, ProviderBalance>>(emptyMap())
    val providerBalances: StateFlow<Map<String, ProviderBalance>> = _providerBalances

    @OptIn(ExperimentalCoroutinesApi::class)
    private val metadataRefreshSignal = metadataRefreshEventBus.events.mapLatest { Unit }

    @OptIn(ExperimentalCoroutinesApi::class)
    val availableModelCounts: StateFlow<Map<String, Int>> = combine(
        providers,
        metadataRefreshSignal,
    ) { currentProviders, _ ->
        currentProviders
    }.mapLatest { currentProviders ->
        currentProviders.associate { provider ->
            provider.id to resolveProviderListAvailableModelCount(provider)
        }
    }
        .flowOn(defaultDispatcher)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    val monthlyCostByProvider: StateFlow<Map<String, Double>> =
        conversationRepository.observeMonthlyCostByConversationProvider()
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    val mergedMonthlyCostByProvider: StateFlow<Map<String, Double>> = monthlyCostByProvider

    val dailyCostsLast7DaysByProvider: StateFlow<Map<String, List<Double>>> =
        MutableStateFlow(emptyMap())

    val monthlyCostSummary: StateFlow<MonthlyCostSummary> = combine(
        conversationRepository.observeMonthlyCostSummary(),
        providers,
    ) { localSummary, currentProviders ->
        CostSummaryCalculator.augmentDisplayNames(localSummary, currentProviders)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), MonthlyCostSummary())

    fun deleteProvider(id: String) {
        viewModelScope.launch {
            runCatching { providerRepository.deleteProvider(id) }
                .onSuccess {
                    generationParameterSettingsStore?.removeScopes(providerID = id)
                    capabilityPreferenceStore?.removeScopes(providerID = id)
                    localCustomFragmentStore?.removeScopes(providerID = id)
                    generationParameterPresetStore?.removeScopes(providerID = id)
                }
        }
    }

    fun refreshProviderBalances() {
        val repository = providerBalanceRepository ?: return
        val currentProviders = providers.value
        val candidates = currentProviders.filter { provider ->
            provider.kind in BALANCE_CAPABLE_KINDS && provider.apiKey.isNotBlank()
        }
        val generation = ++providerBalancesRefreshGeneration
        // Before the first database emission providers is still the empty initial list; pruning
        // then would wipe the shared cache the detail page just filled
        if (currentProviders.isNotEmpty()) {
            repository.retainProviders(candidates.mapTo(mutableSetOf()) { it.id })
        }
        // Don't blank the rows to "--" first: show the last balance for the same key, then replace
        // each one in place as the refresh lands. On a cache hit the map is equal and the StateFlow
        // doesn't re-emit.
        _providerBalances.value = candidates.mapNotNull { provider ->
            repository.cachedBalance(provider)?.let { provider.id to it }
        }.toMap()

        viewModelScope.launch {
            // Apply each result as it arrives so one slow provider doesn't hold back the rest
            candidates.forEach { provider ->
                launch {
                    val balance = repository.fetchBalanceForDisplay(provider)
                    if (providerBalancesRefreshGeneration != generation) return@launch
                    _providerBalances.update { current ->
                        if (balance == null) current - provider.id else current + (provider.id to balance)
                    }
                }
            }
        }
    }
}
