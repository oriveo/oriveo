package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.ConversationInstructions
import ai.oriveo.community.core.context.DirectiveDetection
import ai.oriveo.community.core.context.DirectiveDetector
import ai.oriveo.community.core.context.MemoryIntent
import ai.oriveo.community.core.context.MemoryIntentSuggestion
import ai.oriveo.community.core.context.trimWhiteSpace
import ai.oriveo.community.core.notice.DirectiveSuggestionStore
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A pending "set as instruction" suggestion anchored under one user message. */
data class DirectiveSuggestion(
    val conversationId: String,
    val messageId: String,
    val sentence: String,
)

/**
 * "Set as instruction" suggestion (contract P4·U3 rule 5). Judges only freshly sent user messages; pending
 * suggestions live in memory only (one per conversation) and vanish on the next user message, on switching
 * conversations, or on restart. Accept appends and offers a 5 s undo; ignore bumps the local streak.
 */
class DirectiveSuggestionController(
    private val scope: CoroutineScope,
    private val store: DirectiveSuggestionStore,
    /** Current instructions of a conversation; null when the conversation no longer exists. */
    private val instructionsOf: suspend (conversationId: String) -> String?,
    private val writeInstructions: suspend (conversationId: String, text: String) -> Unit,
    private val showToast: (GlobalSnackbarMessage) -> Unit,
    private val ioContext: CoroutineContext = Dispatchers.IO,
    private val detect: (String) -> DirectiveDetection = DirectiveDetector::detect,
    /** Routing (contract P6·U3 rule 1): only messages classified as a conversation instruction reach this bar. */
    private val classify: (String) -> MemoryIntentSuggestion = { MemoryIntent.classify(it).suggestion },
) {
    private val _pending = MutableStateFlow<Map<String, DirectiveSuggestion>>(emptyMap())
    val pending: StateFlow<Map<String, DirectiveSuggestion>> = _pending.asStateFlow()

    /** Latest user message per conversation: a slower evaluation of an older message must not win. */
    private val latestMessage = java.util.concurrent.ConcurrentHashMap<String, String>()

    fun onUserMessageCreated(conversationId: String, messageId: String, text: String) {
        latestMessage[conversationId] = messageId
        _pending.update { it - conversationId }
        scope.launch {
            val suggestion = withContext(ioContext) { evaluate(conversationId, messageId, text) } ?: return@launch
            if (latestMessage[conversationId] != messageId) return@launch
            _pending.update { it + (conversationId to suggestion) }
        }
    }

    fun accept(conversationId: String) {
        val suggestion = take(conversationId) ?: return
        scope.launch {
            val previous = withContext(ioContext) {
                val current = instructionsOf(conversationId) ?: return@withContext null
                writeInstructions(conversationId, appended(current, suggestion.sentence))
                store.resetIgnores(conversationId)
                current
            } ?: return@launch
            showToast(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.directive_suggestion_added),
                    style = GlobalToastStyle.Success,
                    action = GlobalToastAction(UiText.Resource(R.string.undo)) {
                        scope.launch { withContext(ioContext) { writeInstructions(conversationId, previous) } }
                    },
                    durationMs = UNDO_WINDOW_MS,
                ),
            )
        }
    }

    fun ignore(conversationId: String) {
        take(conversationId) ?: return
        scope.launch { withContext(ioContext) { store.recordIgnore(conversationId) } }
    }

    /** Switching conversations drops every pending suggestion outside [conversationId]; not counted as ignore. */
    fun retainOnly(conversationId: String?) {
        _pending.update { map -> map.filterKeys { it == conversationId } }
    }

    /**
     * P9·U8: the send of [messageId] was rolled back at the confirmation gate; its suggestion goes away (not an
     * ignore) and a late evaluation of it no longer shows. A suggestion under any other message stays.
     */
    fun withdraw(conversationId: String, messageId: String) {
        latestMessage.remove(conversationId, messageId)
        _pending.update { map ->
            if (map[conversationId]?.messageId == messageId) map - conversationId else map
        }
    }

    private fun take(conversationId: String): DirectiveSuggestion? {
        var taken: DirectiveSuggestion? = null
        _pending.update { map ->
            taken = map[conversationId]
            map - conversationId
        }
        return taken
    }

    private suspend fun evaluate(conversationId: String, messageId: String, text: String): DirectiveSuggestion? {
        if (store.ignoreCount(conversationId) >= MAX_IGNORE_STREAK) return null
        if (classify(text) != MemoryIntentSuggestion.CONVERSATION_INSTRUCTION) return null
        val detection = detect(text)
        if (!detection.isDirective) return null
        val sentence = originalSentence(detection.span, text) ?: return null
        val current = instructionsOf(conversationId) ?: return null
        if (current.contains(sentence)) return null
        val next = appended(current, sentence)
        if (next.codePointCount(0, next.length) > ConversationInstructions.MAX_CODE_POINTS) return null
        return DirectiveSuggestion(conversationId, messageId, sentence)
    }

    companion object {
        const val MAX_IGNORE_STREAK = 3
        const val UNDO_WINDOW_MS = 5000L

        /** Original sentence: span trimmed by Unicode White_Space; when that is empty, the whole text trimmed. */
        fun originalSentence(span: String?, text: String): String? =
            span?.trimWhiteSpace()?.takeIf { it.isNotEmpty() }
                ?: text.trimWhiteSpace().takeIf { it.isNotEmpty() }

        fun appended(current: String, sentence: String): String =
            if (current.isEmpty()) sentence else current + "\n" + sentence
    }
}
