package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelRetirement
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.RelayModelFallback

data class ChatConversationState(
    val provider: Provider?,
    val model: AIModel?,
    val issue: ChatConversationIssue? = null,
) {
    val isReadOnly: Boolean
        get() = issue?.isBlocking == true

    /** Sending unavailable: read-only, the relay session model has been removed (the input box stays editable), the session model has been retired, or the session's connection has been deleted. */
    val isSendBlocked: Boolean
        get() = isReadOnly ||
            issue?.removedConnectionName != null ||
            issue?.modelRetirement?.sendBlocked == true ||
            issue?.kind == ChatConversationIssueKind.ProviderMissing
}

enum class ChatConversationIssueKind {
    NoProvidersAvailable,
    ProviderMissing,
    ModelMissing,
    ModelUnavailable,
    /** The official session model has been retired, or is missing from the catalog. */
    ModelRetired,
}

data class ChatConversationIssue(
    val kind: ChatConversationIssueKind,
    val isBlocking: Boolean,
    /** Non-empty = the relay session model has been removed from this connection; the value is the connection display name. */
    val removedConnectionName: String? = null,
    /** Non-null = the verdict for [ChatConversationIssueKind.ModelRetired] (status / displayName / successorId). */
    val modelRetirement: ModelRetirement.ConversationModelStatus? = null,
    /** For [ChatConversationIssueKind.ProviderMissing]: the model stored in the session (banner text argument); the session itself is not rewritten. */
    val missingProviderModelName: String? = null,
    /** false = there is no usable connection at all: "Choose model" opens add-connection instead. */
    val hasUsableConnection: Boolean = true,
) {
    val canRepairFromModelPicker: Boolean
        get() = kind != ChatConversationIssueKind.NoProvidersAvailable && hasUsableConnection

    /** Banners for a removed relay session model, a retired session model and a deleted session connection sit above the input area (ChatComposerHost); the other kinds stay above the message list. */
    val rendersAboveComposer: Boolean
        get() = removedConnectionName != null ||
            kind == ChatConversationIssueKind.ModelRetired ||
            kind == ChatConversationIssueKind.ProviderMissing
}

/** [providerSnapshot] null = the connection list has not been loaded from the repository yet (the ViewModel's initial value). */
fun resolveChatConversationState(
    conversation: Conversation?,
    providerSnapshot: List<Provider>?,
    activeProviderId: String?,
    activeModelId: String?,
    lastUsedModelRef: LastUsedModelRef? = null,
): ChatConversationState = resolveChatConversationState(
    conversation = conversation,
    providers = providerSnapshot.orEmpty(),
    activeProviderId = activeProviderId,
    activeModelId = activeModelId,
    providersLoaded = providerSnapshot != null,
    lastUsedModelRef = lastUsedModelRef,
)

fun resolveChatConversationState(
    conversation: Conversation?,
    providers: List<Provider>,
    activeProviderId: String?,
    activeModelId: String?,
    /** false = the connection list is still loading (initial empty list): do not judge the connection as deleted. No default: callers must say whether the list has loaded. */
    providersLoaded: Boolean,
    /** For sessions with an empty modelID: points at this connection's last use (usable and enabled), taking precedence over the new-chat fallback. */
    lastUsedModelRef: LastUsedModelRef? = null,
): ChatConversationState {
    // The session's connection has been deleted: show a banner plus "Choose model" and block sending; do not fall back to another
    // connection or rewrite the session, only the user's own model choice writes. Judged only once the connection list has loaded:
    // an empty list while loading does not mean the connection was deleted.
    if (providersLoaded && conversation != null && conversation.providerID.isNotBlank() &&
        providers.none { it.id == conversation.providerID }
    ) {
        return ChatConversationState(
            provider = null,
            model = null,
            issue = ChatConversationIssue(
                kind = ChatConversationIssueKind.ProviderMissing,
                isBlocking = false,
                missingProviderModelName = conversation.modelID,
                hasUsableConnection = providers.isNotEmpty(),
            ),
        )
    }
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
        // The caller has already resolved the new-chat chain into activeProviderId; when the chain is empty (no usable connection)
        // the provider stays null and the user picks a model, instead of falling back to the first in the list.
        val provider = activeProviderId?.let { selectedId ->
            providers.firstOrNull { it.id == selectedId }
        }
        val model = provider?.let { selectedProvider ->
            ProviderSelectionSnapshot.currentModel(selectedProvider, activeModelId)
        }
        return ChatConversationState(provider = provider, model = model, issue = null)
    }

    val activeProvider = activeProviderId?.let { selectedId ->
        providers.firstOrNull { it.id == selectedId }
    }
    val conversationProvider = providers.firstOrNull { it.id == conversation.providerID }
    // Neither the user's selection nor the session's connection exists: the provider stays null and the user picks a model, with no fallback to another connection.
    val provider = activeProvider ?: conversationProvider
    val requestedModelId = when {
        activeProvider != null -> activeModelId
        provider?.id == conversation.providerID -> conversation.modelID
        else -> null
    }
    // The official session model has been retired: do not swap in the default model or rewrite the session; the banner guides the user to switch themselves, and every send is blocked.
    ProviderSelectionSnapshot.modelRetirement(provider, requestedModelId)
        ?.takeIf { it.sendBlocked }
        ?.let { retirement ->
            return ChatConversationState(
                provider = provider,
                model = ProviderSelectionSnapshot.selectedModel(provider, requestedModelId),
                issue = ChatConversationIssue(
                    kind = ChatConversationIssueKind.ModelRetired,
                    isBlocking = false,
                    modelRetirement = retirement,
                ),
            )
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
            lastUsedModelRef = lastUsedModelRef,
        )
    }

    return ChatConversationState(
        provider = provider,
        model = model,
        issue = null,
    )
}

/**
 * Whether the current selection ([activeProviderId] / [activeModelId]) should be replaced by the resolved state after the
 * conversation state is resolved; returns the (providerId, modelId) to write, null = unchanged. Extracted from ChatViewModel,
 * same domain as [resolveChatConversationState].
 */
internal fun conversationSelectionToSync(
    providerList: List<Provider>,
    activeProviderId: String?,
    activeModelId: String?,
    resolvedState: ChatConversationState,
): Pair<String, String?>? {
    // The session connection is deleted: activeProviderId / activeModelId keep the stored session values and are not replaced by another connection.
    if (resolvedState.issue?.kind == ChatConversationIssueKind.ProviderMissing) return null
    val resolvedProvider = resolvedState.provider ?: return null
    // The relay session model was removed: keep the session's original selection until the user re-picks in the picker.
    if (resolvedState.issue?.removedConnectionName != null) return null
    // The official session model is retired: activeModelId keeps the stored session value and is not replaced by the default.
    if (resolvedState.issue?.kind == ChatConversationIssueKind.ModelRetired) return null
    val activeProvider = activeProviderId?.let { selectedId -> providerList.firstOrNull { it.id == selectedId } }
    val activeModel = activeProvider?.let { provider -> ProviderSelectionSnapshot.currentModel(provider, activeModelId) }
    if (activeProvider?.id == resolvedProvider.id && activeModel?.id == resolvedState.model?.id) return null
    return resolvedProvider.id to
        resolvedState.model?.let { ModelSelectionUtils.preferredStoredModelIdentifier(it, resolvedProvider.kind) }
}
