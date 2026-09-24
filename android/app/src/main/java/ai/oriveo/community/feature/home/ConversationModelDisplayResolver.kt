package ai.oriveo.community.feature.home

import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelDisplayLookup

internal fun resolveConversationModelName(
    conversation: Conversation,
    provider: Provider?,
    displayLookup: ModelDisplayLookup,
): String {
    if (provider == null) return conversation.modelID

    // The fallback is computed only when the lookup has no answer (a hit never reads it, so the result is the same as
    // computing it first), and it looks enabled models up in the lookup's index: after "add all" the enabled models
    // are the whole relay catalog, which every row used to compare one by one.
    return displayLookup.modelDisplayName(
        providerId = provider.id,
        modelId = conversation.modelID,
        fallback = null,
    ) ?: displayLookup.selectedModel(provider, conversation.modelID)?.name
        ?: conversation.modelID
}
