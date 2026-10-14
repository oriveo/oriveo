package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.RelayModelFallback

data class ChatConversationState(
    val provider: Provider?,
    val model: AIModel?,
    val issue: ChatConversationIssue? = null,
) {
    val isReadOnly: Boolean
        get() = issue?.isBlocking == true

    /** Sending unavailable: read-only, or the relay session model has been removed (the input box stays editable). */
    val isSendBlocked: Boolean
        get() = isReadOnly || issue?.removedConnectionName != null
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
    /** Non-empty = the relay session model has been removed from this connection; the value is the connection display name. */
    val removedConnectionName: String? = null,
) {
    val canRepairFromModelPicker: Boolean
        get() = kind != ChatConversationIssueKind.NoProvidersAvailable

    /** The banner for a removed relay session model sits above the input area (ChatComposerHost); the other kinds stay above the message list. */
    val rendersAboveComposer: Boolean
        get() = removedConnectionName != null
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
    // The relay session model is no longer among the enabled models: do not replace it silently, prompt the user to pick again, and block every send.
    RelayModelFallback.removedConnectionName(provider, requestedModelId)?.let { connectionName ->
        return ChatConversationState(
            provider = provider,
            model = null,
            issue = ChatConversationIssue(
                kind = ChatConversationIssueKind.ModelMissing,
                isBlocking = false,
                removedConnectionName = connectionName,
            ),
        )
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
