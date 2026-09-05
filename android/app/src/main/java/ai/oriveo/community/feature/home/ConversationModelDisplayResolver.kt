package ai.oriveo.community.feature.home

import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot

internal fun resolveConversationModelName(
    conversation: Conversation,
    provider: Provider?,
    displayLookup: ModelDisplayLookup,
): String {
    if (provider == null) return conversation.modelID

    val fallback = ProviderSelectionSnapshot.selectedModel(provider, conversation.modelID)?.name
        ?: conversation.modelID

    return displayLookup.modelDisplayName(
        providerId = provider.id,
        modelId = conversation.modelID,
        fallback = fallback,
    ) ?: fallback
}
