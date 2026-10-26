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
 * "Set as instruction" suggestion. Judges only freshly sent user messages; pending
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
    /** Routing: only messages classified as a conversation instruction reach this bar. */
    private val classify: (String) -> MemoryIntentSuggestion = { MemoryIntent.classify(it).suggestion },
) {
    private val _pending = MutableStateFlow<Map<String, DirectiveSuggestion>>(emptyMap())
    val pending: StateFlow<Map<String, DirectiveSuggestion>> = _pending.asStateFlow()

    /** Latest user message per conversation: a slower evaluation of an older message must not win. */
    private val latestMessage = java.util.concurrent.ConcurrentHashMap<String, String>()

    /**
     * A fresh user message: clears the pending bar. [lexical] false is propose mode tool (propose-v3): the bar then
     * only comes from [onInstruct], the lexical route does not run.
     */
    fun onUserMessageCreated(conversationId: String, messageId: String, text: String, lexical: Boolean = true) {
        latestMessage[conversationId] = messageId
        _pending.update { it - conversationId }
        if (lexical) onFallback(conversationId, messageId, text)
    }

    /**
     * Lexical route for [messageId] (mode fallback / none, or a tool-mode send degraded to no tools): memory-intent
     * classify plus the detector, offered only when the matched language is in suggestionLanguages.
     */
    fun onFallback(conversationId: String, messageId: String, text: String) {
        offer(conversationId, messageId) { lexicalSentence(text) }
    }

    /** propose-v3 instruct outcome of the turn started by [messageId]: same ignore / substring / length gates. */
    fun onInstruct(conversationId: String, messageId: String, sentence: String) {
        offer(conversationId, messageId) { sentence.trimWhiteSpace().takeIf { it.isNotEmpty() } }
    }

    private fun offer(conversationId: String, messageId: String, sentenceOf: () -> String?) {
        if (latestMessage[conversationId] != messageId) return
        scope.launch {
            val suggestion = withContext(ioContext) {
                val sentence = sentenceOf() ?: return@withContext null
                evaluate(conversationId, messageId, sentence)
            } ?: return@launch
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
     * the send of [messageId] was rolled back at the confirmation gate; its suggestion goes away (not an
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

    private fun lexicalSentence(text: String): String? {
        if (classify(text) != MemoryIntentSuggestion.CONVERSATION_INSTRUCTION) return null
        val detection = detect(text)
        if (!detection.isDirective || detection.lang !in DirectiveDetector.SUGGESTION_LANGUAGES) return null
        return originalSentence(detection.span, text)
    }

    private suspend fun evaluate(conversationId: String, messageId: String, sentence: String): DirectiveSuggestion? {
        if (store.ignoreCount(conversationId) >= MAX_IGNORE_STREAK) return null
        val current = instructionsOf(conversationId) ?: return null
        if (!shows(sentence, current, ignoreCount = 0)) return null
        return DirectiveSuggestion(conversationId, messageId, sentence)
    }

    companion object {
        const val MAX_IGNORE_STREAK = 3
        const val UNDO_WINDOW_MS = 5000L

        /** Original sentence: span trimmed by Unicode White_Space; when that is empty, the whole text trimmed. */
        fun originalSentence(span: String?, text: String): String? =
            span?.trimWhiteSpace()?.takeIf { it.isNotEmpty() }
                ?: text.trimWhiteSpace().takeIf { it.isNotEmpty() }

        /** §10.1 bar gate: ignore streak < 3, not already in the instructions, appended text within the limit. */
        fun shows(sentence: String, instructions: String, ignoreCount: Int): Boolean {
            if (ignoreCount >= MAX_IGNORE_STREAK || instructions.contains(sentence)) return false
            val next = appended(instructions, sentence)
            return next.codePointCount(0, next.length) <= ConversationInstructions.MAX_CODE_POINTS
        }

        fun appended(current: String, sentence: String): String =
            if (current.isEmpty()) sentence else current + "\n" + sentence
    }
}
