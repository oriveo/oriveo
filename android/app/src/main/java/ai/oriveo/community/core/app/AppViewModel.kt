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
import ai.oriveo.community.core.model.resolveLastUsedModelRef
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.UnsupportedParamNoticeBus
import ai.oriveo.community.core.app.GlobalToastStyle
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
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

    val globalMessages = globalSnackbarManager.messages

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

        viewModelScope.launch {
            combine(providers, lastUsedModelRef, ::resolveLastUsedModelRef)
                .distinctUntilChanged()
                .collect { resolvedRef ->
                    val currentRef = lastUsedModelRef.value
                    when {
                        resolvedRef == null && currentRef != null -> {
                            appPreferencesRepository.clearLastUsedModel()
                        }
                        resolvedRef != null && resolvedRef != currentRef -> {
                            appPreferencesRepository.setLastUsedModel(
                                providerId = resolvedRef.providerID,
                                modelId = resolvedRef.modelID,
                            )
                        }
                    }
                }
        }
    }

    fun setActiveModel(providerId: String, modelId: String) {
        appPreferencesRepository.primeLastUsedModel(providerId, modelId)
        viewModelScope.launch {
            val provider = providers.value.firstOrNull { it.id == providerId }
            val selection = ProviderSelectionSnapshot.persistedSelection(provider, modelId)
            if (selection?.model != null) {
                appPreferencesRepository.setLastUsedModel(providerId, selection.model)
            } else {
                appPreferencesRepository.setLastUsedModel(
                    providerId = providerId,
                    modelId = selection?.storedModelId ?: ModelSelectionUtils.resolvedId(modelId),
                )
            }
        }
    }

    /** Called once the first frame is on screen, so startup work does not compete with it. */
    fun markUiReady() {
        viewModelScope.launch { skillRepository.refreshAll() }
    }
}
