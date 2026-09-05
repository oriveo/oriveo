package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot

data class ChatConversationState(
    val provider: Provider?,
    val model: AIModel?,
    val issue: ChatConversationIssue? = null,
) {
    val isReadOnly: Boolean
        get() = issue?.isBlocking == true
}

enum class ChatConversationIssueKind {
    NoProvidersAvailable,
    ProviderMissing,
    ModelMissing,
    ModelUnavailable,
}

data class ChatConversationIssue(
    val kind: ChatConversationIssueKind,
    val isBlocking: Boolean,
) {
    val canRepairFromModelPicker: Boolean
        get() = kind != ChatConversationIssueKind.NoProvidersAvailable
}

fun resolveChatConversationState(
    conversation: Conversation?,
    providers: List<Provider>,
    activeProviderId: String?,
    activeModelId: String?,
): ChatConversationState {
    if (providers.isEmpty()) {
        if (conversation != null) {
            return ChatConversationState(
                provider = null,
                model = null,
                issue = null,
            )
        }
        return ChatConversationState(
            provider = null,
            model = null,
            issue = ChatConversationIssue(ChatConversationIssueKind.NoProvidersAvailable, isBlocking = true),
        )
    }

    if (conversation == null) {
        val provider = activeProviderId?.let { selectedId ->
            providers.firstOrNull { it.id == selectedId }
        } ?: resolveActiveModel(providers, lastUsedModelRef = null)?.provider
            ?: providers.firstOrNull()
        val model = provider?.let { selectedProvider ->
            ProviderSelectionSnapshot.currentModel(selectedProvider, activeModelId)
        }
        return ChatConversationState(provider = provider, model = model, issue = null)
    }

    val activeProvider = activeProviderId?.let { selectedId ->
        providers.firstOrNull { it.id == selectedId }
    }
    val conversationProvider = providers.firstOrNull { it.id == conversation.providerID }
    val provider = activeProvider
        ?: conversationProvider
        ?: resolveActiveModel(providers, lastUsedModelRef = null)?.provider
        ?: providers.firstOrNull()
    val requestedModelId = when {
        activeProvider != null -> activeModelId
        provider?.id == conversation.providerID -> conversation.modelID
        else -> null
    }
    val model = provider?.let { selectedProvider ->
        ProviderSelectionSnapshot.currentModel(
            provider = selectedProvider,
            storedModelId = requestedModelId,
        )
    }

    return ChatConversationState(
        provider = provider,
        model = model,
        issue = null,
    )
}
