package ai.oriveo.community.feature.chat

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.model.QuoteSelectionContent

internal class ChatQuoteCoordinator {
    var pending: QuoteContext? by mutableStateOf(null)
        private set
    private var attachedAtMillis: Long? = null

    fun attach(message: ChatMessage, selection: QuoteSelectionContent): Boolean {
        val quote = QuoteContext.capture(
            sourceMessageId = message.id,
            sourceRole = message.role,
            contentKind = selection.contentKind,
            leadingText = selection.leadingText,
            selectedText = selection.selectedText,
            trailingText = selection.trailingText,
        ).getOrNull()?.takeIf { it.isValid } ?: return false
        pending = quote
        attachedAtMillis = System.currentTimeMillis()
        return true
    }

    fun remove() {
        clear()
    }

    fun consume(quote: QuoteContext?) {
        if (pending == quote) clear()
    }

    fun restore(quote: QuoteContext?) {
        pending = quote?.takeIf { it.isValid }
        attachedAtMillis = pending?.let { System.currentTimeMillis() }
    }

    fun clear() {
        pending = null
        attachedAtMillis = null
    }

}
