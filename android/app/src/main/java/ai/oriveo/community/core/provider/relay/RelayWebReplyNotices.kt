package ai.oriveo.community.core.provider.relay

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Relay web reply notice (fixture `web-probe.v1.json` chatCases `replyNotice`): when the switch is on but the delivered request carried no web fragment,
 * a one-line secondary-color note under that assistant reply.
 *
 * Kept in this process's memory only: no message field, no database, no cloud sync; it disappears after a restart. The key is the assistant message id.
 */
class RelayWebReplyNotices {
    enum class Notice(val wire: String) {
        WebNotUsed("web_not_used"),
    }

    private val notices = MutableStateFlow<Map<String, Notice>>(emptyMap())

    val all: StateFlow<Map<String, Notice>> = notices.asStateFlow()

    fun of(messageId: String): Notice? = notices.value[messageId]

    /** [notice] = null clears it (after the same message is regenerated / continued it is recomputed from the new delivery). */
    fun set(messageId: String, notice: Notice?) {
        notices.update { current -> if (notice == null) current - messageId else current + (messageId to notice) }
    }

    companion object {
        val shared = RelayWebReplyNotices()
    }
}
