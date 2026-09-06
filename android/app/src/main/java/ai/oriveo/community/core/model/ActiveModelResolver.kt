package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import ai.oriveo.community.core.provider.ModelSelectionUtils

@Immutable
data class ActiveModelSelection(
    val provider: Provider,
    val model: AIModel,
)

fun resolveActiveModel(
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
): ActiveModelSelection? {
    if (providers.isEmpty()) return null

    if (lastUsedModelRef != null) {
        val provider = providers.firstOrNull { it.id == lastUsedModelRef.providerID }
        val model = provider?.models?.let { models ->
            ModelSelectionUtils.matchingModel(models, lastUsedModelRef.modelID)
        }
            ?: provider?.defaultModel
            ?: provider?.models?.firstOrNull()
        if (provider != null && model != null) {
            return ActiveModelSelection(provider, model)
        }
    }

    val fallbackProvider = providers.firstOrNull { it.status is ProviderConnectionState.Connected }
        ?: providers.firstOrNull()
        ?: return null
    val fallbackModel = fallbackProvider.defaultModel ?: fallbackProvider.models.firstOrNull() ?: return null
    return ActiveModelSelection(fallbackProvider, fallbackModel)
}

fun resolveLastUsedModelRef(
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
): LastUsedModelRef? {
    if (lastUsedModelRef != null) {
        val provider = providers.firstOrNull { it.id == lastUsedModelRef.providerID }
            ?: return lastUsedModelRef
        val model = ModelSelectionUtils.matchingModel(provider.models, lastUsedModelRef.modelID)
            ?: return lastUsedModelRef
        return LastUsedModelRef(
            providerID = provider.id,
            modelID = ModelSelectionUtils.preferredStoredModelIdentifier(model),
        )
    }

    val activeModel = resolveActiveModel(providers, lastUsedModelRef = null) ?: return null
    return LastUsedModelRef(
        providerID = activeModel.provider.id,
        modelID = ModelSelectionUtils.preferredStoredModelIdentifier(activeModel.model),
    )
}

fun resolveActiveModelProviderIssue(
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
): String? {
    val activeModel = resolveActiveModel(providers, lastUsedModelRef) ?: return null
    val status = activeModel.provider.status
    return if (status is ProviderConnectionState.Issue) status.message else null
}

@Immutable
data class ProviderIssueInfo(
    val providerID: String,
    val providerName: String,
    val message: String,
)

fun resolveProviderIssue(
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
): ProviderIssueInfo? {
    val activeModel = resolveActiveModel(providers, lastUsedModelRef)
    if (activeModel != null) {
        val status = activeModel.provider.status
        return if (status is ProviderConnectionState.Issue) {
            ProviderIssueInfo(activeModel.provider.id, activeModel.provider.displayName, status.message)
        } else null
    }

    if (lastUsedModelRef != null) {
        val provider = providers.firstOrNull { it.id == lastUsedModelRef.providerID }
        if (provider != null) {
            val status = provider.status
            if (status is ProviderConnectionState.Issue) {
                return ProviderIssueInfo(provider.id, provider.displayName, status.message)
            }
        }
    }

    val fallback = providers.firstOrNull { it.status is ProviderConnectionState.Issue }
    if (fallback != null) {
        val status = fallback.status as ProviderConnectionState.Issue
        return ProviderIssueInfo(fallback.id, fallback.displayName, status.message)
    }
    return null
}
