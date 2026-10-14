package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import kotlin.coroutines.cancellation.CancellationException

internal sealed interface EnableCatalogModelResult {
    data class Added(val model: AIModel, val providerKind: ProviderKind) : EnableCatalogModelResult

    /** An equivalent model is already enabled: idempotent, neither a failure nor worth a message. */
    data object AlreadyEnabled : EnableCatalogModelResult

    /** The provider was removed, or the id is not in its catalog. */
    data object NotFound : EnableCatalogModelResult
}

/**
 * Adds a catalog model to a provider's enabled list.
 *
 * Shared by the Home, chat and notes model pickers. Each used to carry its own copy: two of them
 * looked the model up with `ProviderSelectionSnapshot.selectedModel` (which searches the *enabled*
 * models, not the catalog), and every copy returned silently when the model was missing or already
 * present, so tapping "+" showed nothing and left the list unchanged.
 */
internal suspend fun enableCatalogModel(
    providerRepository: ProviderRepository,
    providerId: String,
    modelId: String,
): EnableCatalogModelResult {
    val provider = providerRepository.getById(providerId) ?: return EnableCatalogModelResult.NotFound
    val model = ModelSelectionUtils.matchingModel(provider.allModels, modelId, provider.kind)
        ?: return EnableCatalogModelResult.NotFound
    // Enabling on a multi-key relay binds one key, the one the catalog lists the model under or the same family's; with a single key nothing is written.
    val updated = ModelSelectionUtils.enableModel(provider, RelayKeyBinding.withBinding(provider, model))
    // enableModel hands back its argument untouched when an equivalent model is already enabled.
    if (updated === provider) return EnableCatalogModelResult.AlreadyEnabled
    providerRepository.updateProvider(updated)
    return EnableCatalogModelResult.Added(model, provider.kind)
}

/** [enableCatalogModel] plus user-visible feedback: a success toast, or a failure message. */
internal suspend fun enableCatalogModelWithFeedback(
    providerRepository: ProviderRepository,
    globalSnackbarManager: GlobalSnackbarManager,
    providerId: String,
    modelId: String,
) {
    // Failure uses the Error style (matching iOS `.error`) so it reads differently from the "Added" success at a glance
    val failure = GlobalSnackbarMessage(
        message = UiText.Resource(R.string.snackbar_model_enable_failed),
        style = GlobalToastStyle.Error,
    )
    val added = try {
        when (val result = enableCatalogModel(providerRepository, providerId, modelId)) {
            is EnableCatalogModelResult.Added -> {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.snackbar_model_added, listOf(result.model.name)),
                        style = GlobalToastStyle.Success,
                    ),
                )
                result.takeIf { it.providerKind == ProviderKind.Relay }?.model
            }
            EnableCatalogModelResult.AlreadyEnabled -> null
            EnableCatalogModelResult.NotFound -> {
                globalSnackbarManager.show(failure)
                null
            }
        }
    } catch (cancellation: CancellationException) {
        throw cancellation
    } catch (_: Exception) {
        globalSnackbarManager.show(failure)
        null
    }
    // After enabling a single Relay model, verify it lazily; the repository re-checks the form and swallows probe failures, so the enable already saved is unaffected.
    added?.let { providerRepository.probeEnabledRelayModel(providerId, it.id) }
}
