package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.streaming.ChatStreamingManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal class ChatDraftCoordinator(
    private val viewModelScope: CoroutineScope,
    private val conversationRepository: ConversationRepository,
) {
    private var draftFlushJob: Job? = null

    fun onInputTextChanged(
        text: String,
        conversationId: String?,
        updateInput: (String) -> Unit,
    ) {
        updateInput(text)
        if (conversationId == null) return
        draftFlushJob?.cancel()
        draftFlushJob = viewModelScope.launch {
            delay(350)
            conversationRepository.updateDraft(conversationId, text)
        }
    }

    fun flushDraft(conversationId: String?, inputText: String) {
        if (conversationId == null) return
        draftFlushJob?.cancel()
        draftFlushJob = null
        viewModelScope.launch {
            conversationRepository.updateDraft(conversationId, inputText)
        }
    }

    /**
     * Drops the debounced draft write that has not landed yet.
     *
     * Sending must call this before it clears the draft. Otherwise the write queued by the last
     * keystroke runs after the clear and puts the just-sent text back into the draft, leaving a
     * ghost draft that reappears every time the conversation is opened.
     */
    fun cancelPendingFlush() {
        draftFlushJob?.cancel()
        draftFlushJob = null
    }
}

internal class ChatConversationActions(
    private val viewModelScope: CoroutineScope,
    private val applicationScope: CoroutineScope,
    private val conversationRepository: ConversationRepository,
    private val chatStreamingManager: ChatStreamingManager,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val currentConversationId: () -> String?,
    private val generationParameterSettingsStore: GenerationParameterSettingsStore,
    private val capabilityPreferenceStore: CapabilityPreferenceStore,
    private val localCustomFragmentStore: LocalCapabilityCustomFragmentStore,
) {
    fun toggleUseMemory(useMemory: Boolean) {
        val convId = currentConversationId() ?: return
        viewModelScope.launch {
            conversationRepository.updateUseMemory(convId, !useMemory)
        }
    }

    fun deleteConversation(markUserInitiatedExit: () -> Unit) {
        val convId = currentConversationId() ?: return
        markUserInitiatedExit()
        chatStreamingManager.stopStream(convId)
        // Deletion has to run on applicationScope. The caller pops the screen the moment the user
        // confirms, which cancels viewModelScope while delete() is still suspended part way
        // through hydrating the conversation's messages. A cancellation there leaves the
        // conversation half deleted.
        applicationScope.launch {
            conversationRepository.delete(convId)
            generationParameterSettingsStore.removeScopes(conversationID = convId)
            capabilityPreferenceStore.removeScopes(conversationID = convId)
            localCustomFragmentStore.removeScopes(conversationID = convId)
            globalSnackbarManager.show(
                GlobalSnackbarMessage(message = UiText.Resource(R.string.chat_conversation_deleted)),
            )
        }
    }
}
