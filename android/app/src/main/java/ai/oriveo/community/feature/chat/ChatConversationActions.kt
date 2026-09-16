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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * A one-shot "push this text back into the composer" request.
 *
 * [token] is bumped on every external write, [text] is what should replace the field. The composer
 * only overwrites its local text when the token changes, so typing is never interrupted by it, and
 * pushing the same text twice in a row (two clears, say) still takes effect twice.
 */
data class ChatComposerTextRestore(val token: Long, val text: String)

/**
 * Sole owner of the composer text and of the debounced draft write.
 *
 * The text is deliberately **not** Compose snapshot state. It used to be a `mutableStateOf` on
 * `ChatViewModel` that `ChatScreenContent` read in its root function body, so every keystroke
 * invalidated the whole screen. Once `ChatMessagesList` recomposes with it, foundation's
 * `rememberLazyListItemProviderLambda` swaps in a fresh `LazyListIntervalContent` and **every
 * visible cell, markdown subtree included, recomposes**.
 *
 * Per-keystroke text now lives in `ChatComposerHost`'s local state. What stays here is the
 * outbound truth (sending, draft persistence and note recall all read it) plus the one-shot
 * push-back channel [restore].
 */
internal class ChatDraftCoordinator(
    private val viewModelScope: CoroutineScope,
    private val conversationRepository: ConversationRepository,
) {
    private var draftFlushJob: Job? = null

    /** Input source for note recall. `snapshotFlow` cannot observe a non-snapshot field, so related notes subscribe to this flow. */
    val textFlow = MutableStateFlow("")

    /** Outbound truth for the composer text. Writing it only updates [textFlow]; the snapshot system is never touched. */
    var text: String
        get() = textFlow.value
        set(value) {
            textFlow.value = value
        }

    /** One-shot push-back request; only external writes bump the token, typing never does. */
    var restore: ChatComposerTextRestore by mutableStateOf(ChatComposerTextRestore(0L, ""))
        private set

    /** External write into the composer (draft hydration, clear after send, new chat): update the truth and bump the token. */
    fun pushText(text: String) {
        this.text = text
        restore = ChatComposerTextRestore(restore.token + 1, text)
    }

    /** External restore (inline message edit): push to the composer and still go through the draft debounce. */
    fun restoreText(text: String, conversationId: String?) {
        pushText(text)
        onInputTextChanged(text, conversationId)
    }

    /**
     * Typing: update the outbound truth and queue a draft write 350ms out, replacing the pending one.
     *
     * It deliberately does **not** bump [restore]'s token -- doing so would push the text straight
     * back into the composer on every keystroke. This used to call back into `updateInput` to write
     * a `mutableStateOf`, which wrote into the snapshot system once per keystroke and dragged the
     * whole chat screen into the recomposition queue.
     */
    fun onInputTextChanged(text: String, conversationId: String?) {
        this.text = text
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
