package ai.oriveo.community.feature.chat

import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.realtime.RealtimeSelection
import ai.oriveo.community.core.voice.realtime.realtimeCatalogChanges
import ai.oriveo.community.feature.chat.voice.ViewModelVoiceChatPort
import ai.oriveo.community.feature.chat.voice.VoiceConversationTarget
import ai.oriveo.community.feature.chat.voice.lastTextModelToRestore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.launch

/**
 * The Chat target of realtime voice on this chat page: the context for the opening and the re-plan at turn boundaries
 * comes from [ChatSendCoordinator.realtimeSessionContext];
 * a draft ([conversationId] empty) creates its conversation through [ChatViewModel.createFirstConversation] on the first-send path
 * (onConversationActivated -> flushPendingPinnedNotes), and the opening plan uses [ChatViewModel.plannedFirstConversation].
 * The host only calls here and does not assemble this itself.
 * Kept outside the ViewModel file: ChatViewModelStructureTest locks the logical-line budget of ChatViewModel.kt, and wiring functions do not count against it.
 */
internal fun ChatViewModel.realtimeVoiceTarget(
    conversationId: String?,
    onOpenConnection: (String) -> Unit = {},
    openModelPicker: () -> Unit = {},
    lastUsedModel: suspend () -> LastUsedModelRef? = { null },
    /** Same display name as the top bar (used in the switch-responder hint). */
    modelName: String? = null,
): VoiceConversationTarget.Chat = VoiceConversationTarget.Chat(
    conversationId = conversationId,
    context = { conversation -> sendCoordinator.realtimeSessionContext(conversation, currentMemoryItems.value) },
    createConversation = this::createFirstConversation,
    newConversation = this::plannedFirstConversation,
    onOpenConnection = onOpenConnection,
    onSwitchModel = { restore ->
        if (restore) {
            viewModelScope.launch {
                restoreLastTextModel(lastUsedModel())
                openModelPicker()
            }
        } else {
            openModelPicker()
        }
    },
    realtimeSelection = selectedRealtimeVoice(),
    // Migration dialog "Switch to <model>": selects the realtime model from the old settings for this session (does not write last-used).
    onSelectRealtime = { selectModel(it.connectionId, it.model) },
    modelName = modelName,
) { ViewModelVoiceChatPort.of(this) }

/** Realtime model selected for this session (connection + model); tapping the voice orb opens it. Null when the selection is not a realtime model. The voice comes from the catalog default. */
internal fun ChatViewModel.selectedRealtimeVoice(): VoiceEngineSelection.Cloud? {
    // Provider and model are both read from the current in-memory selection (same source as engine switching): after a cross-provider change, do not wait for the conversation DB to flow back,
    // and do not use activeProvider() (it prefers the old provider from the conversation projection).
    val provider = providers.value.find { it.id == activeProviderId } ?: return null
    val modelId = activeModelId ?: return null
    if (!RealtimeSelection.isRealtime(provider, modelId, voiceCatalog())) return null
    return VoiceEngineSelection.Cloud(providerKind = provider.kind, connectionId = provider.id, model = modelId)
}

/**
 * "Change model" on the realtime failure card (model_gone): first switches this conversation back to the last-used text model via [ChatViewModel.selectModel]
 * (ChatModelSelectionCoordinator), then the caller opens the picker. When the last-used model is empty or no longer valid, the selection is unchanged and it returns false.
 */
internal fun ChatViewModel.restoreLastTextModel(lastUsed: LastUsedModelRef?): Boolean {
    val ref = lastTextModelToRestore(providers.value, lastUsed) ?: return false
    selectModel(ref.providerID, ref.modelID)
    return true
}

/** Whether the selected model is a realtime voice model (the single authoritative check): the composer's typing state projects attachments / tools / primary key from RealtimeModel.capability. */
internal fun ChatViewModel.isRealtimeModelSelected(): Boolean =
    RealtimeSelection.isRealtime(activeProvider(), activeModelId, voiceCatalog())

/**
 * Attachment capability control. Image / native file / video read the input capability projection; text inline files read the connection envelope / provider attachmentSupport,
 * see [ChatModelCapabilityResolver.attachmentInputGate]. When a realtime model is selected, it is projected by typing state.
 */
internal fun ChatViewModel.attachmentEntryModel(localIdentity: CapabilityEvidenceIdentity? = null) =
    capabilityResolver.attachmentEntryModel(
        activeProvider(),
        conversationState.model,
        localIdentity,
        realtime = isRealtimeModelSelected(),
    )

/** Realtime voice on a draft: creates the conversation through the first-send path, without sending. */
internal suspend fun ChatViewModel.createFirstConversation(): String? =
    sendCommandCoordinator.createFirstConversation(activeProviderId, activeModelId)

/** The conversation a first send would create (not stored), for a realtime plan on a draft. */
internal suspend fun ChatViewModel.plannedFirstConversation(): Conversation? =
    sendCommandCoordinator.plannedFirstConversation(activeProviderId, activeModelId)

/**
 * The voice catalog arrives late at cold start, or the catalog is swapped: when catalog content changes, recompute the conversation state once for the current selection and sync the selection
 * (the voice dock appears, and send goes realtime). Triggers only on catalog content changes (identical content is not re-evaluated), with no polling; collected in the caller's scope (stops when the host leaves).
 * The first value is also evaluated on subscription, so a catalog that arrived while the host was away is still picked up; nothing is written when the result matches the current state
 * (a second pass over the same snapshot writes nothing). If the connection list is not loaded yet, the latest catalog is remembered; the re-evaluation runs once both the catalog and the first non-null connection list have arrived,
 * regardless of which comes first. Afterwards it triggers only on catalog changes; connection-list changes are still handled by the combine in init.
 */
internal suspend fun ChatViewModel.recomputeWhenVoiceCatalogReady(states: Flow<VoiceCatalogState?>) {
    combine(states.realtimeCatalogChanges(), loadedProviders.filterNotNull().take(1)) { catalog, _ -> catalog }.collect {
        val snapshot = loadedProviders.value ?: return@collect
        // Selection staged while the catalog was not ready: re-evaluate whether to write last-used once the catalog arrives.
        modelSelectionCoordinator.resolvePendingSelection(it, snapshot)
        val resolved = resolveConversationState(conversation.value.conversation ?: bootstrapConversation, snapshot, lastUsedModelRef.value)
        if (resolved != conversationState) conversationState = resolved
        syncResolvedConversationSelectionIfNeeded(snapshot, conversationState)
    }
}
