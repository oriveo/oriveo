package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal class ChatModelSelectionCoordinator(
    private val viewModelScope: CoroutineScope,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val providerRepository: ProviderRepository,
    private val conversationRepository: ConversationRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val providers: () -> List<Provider>,
    private val activeProviderId: () -> String?,
    private val activeModelId: () -> String?,
    private val activeConversationId: () -> String?,
    private val onProviderResolutionError: (Throwable) -> Unit = {},
) {
    fun selectModel(
        providerId: String,
        modelId: String,
        onSelectionChanged: (String, String) -> Unit,
    ) {
        val previousProviderId = activeProviderId()
        val previousModelId = activeModelId()
        val previousProviderKind = previousProviderId
            ?.let { id -> providers().firstOrNull { it.id == id }?.kind }
        val newProviderKind = providers().firstOrNull { it.id == providerId }?.kind

        onSelectionChanged(providerId, modelId)
        // Prime the override synchronously so the empty-conversation combine collector and
        // the first send on the home screen immediately see the new selection, instead of
        // getting overwritten back to the old model by the async lastUsedModelRef (this was
        // the fix for "picking a model once doesn't take, you have to pick it twice").
        appPreferencesRepository.primeLastUsedModel(providerId, modelId)

        if (previousModelId != null && (previousModelId != modelId || previousProviderId != providerId)) {
        }

        viewModelScope.launch {
            val provider = resolveChatProvider(
                providerRepository = providerRepository,
                providerId = providerId,
                onFailure = onProviderResolutionError,
            ) ?: return@launch
            val selectedModel = ProviderSelectionSnapshot.selectedModel(provider, modelId)
            val storedModelId = selectedModel?.let(ModelSelectionUtils::preferredStoredModelIdentifier)
                ?: ModelSelectionUtils.resolvedId(modelId)

            if (selectedModel != null) {
                appPreferencesRepository.setLastUsedModel(providerId, selectedModel)
            } else {
                appPreferencesRepository.setLastUsedModel(providerId, storedModelId)
            }

            activeConversationId()?.let { convId ->
                conversationRepository.updateProviderAndModel(
                    id = convId,
                    providerId = providerId,
                    providerKind = provider.kind,
                    modelId = storedModelId,
                    relayKind = provider.relayKind,
                )
            }
        }
    }

    fun enableModel(providerId: String, modelId: String) {
        viewModelScope.launch {
            try {
                val provider = providerRepository.getById(providerId) ?: return@launch
                val model = ProviderSelectionSnapshot.selectedModel(provider, modelId) ?: return@launch

                providerRepository.updateProvider(
                    ModelSelectionUtils.enableModel(provider, model),
                )
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.snackbar_model_enable_failed),
                    ),
                )
            }
        }
    }
}
