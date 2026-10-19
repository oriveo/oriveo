package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole

/** Sanitized history plus how many earlier users were folded into a later one. */
internal data class ContextSanitizeResult(
    val messages: List<ContextMessage>,
    val unansweredMerged: Int,
)

/**
 * Outbound history sanitize (sanitize.v1.json). Assistant media is stripped, empty and failed
 * (unless kept) messages dropped, adjacent users folded into an unanswered envelope, adjacent
 * assistants joined.
 */
object ContextSanitizer {
    const val UNANSWERED_TAG: String = "oriveo-unanswered"

    const val UNANSWERED_NOTE: String =
        "The user sent this earlier but no reply was delivered. Treat it as context and answer the latest message."

    fun sanitize(messages: List<ContextMessage>, keepAssistantId: String? = null): List<ContextMessage> =
        sanitizeCounting(messages, keepAssistantId).messages

    internal fun sanitizeCounting(messages: List<ContextMessage>, keepAssistantId: String? = null): ContextSanitizeResult {
        val filtered = messages.mapNotNull { msg ->
            val normalized = if (msg.role == ChatRole.Assistant && msg.attachments.isNotEmpty()) {
                msg.copy(attachments = msg.attachments.filter { it.kind != AttachmentKind.Image && it.kind != AttachmentKind.Video })
            } else {
                msg
            }
            val hasContent = normalized.text.trimWhiteSpace().isNotEmpty() || normalized.attachments.isNotEmpty()
            if (!hasContent) return@mapNotNull null
            val keep = normalized.role == ChatRole.User ||
                normalized.id == keepAssistantId ||
                normalized.state != ChatMessageState.Failed
            if (keep) normalized else null
        }

        val merged = mutableListOf<ContextMessage>()
        var foldedUsers = 0
        val pendingUsers = mutableListOf<ContextMessage>()
        fun flushUsers() {
            if (pendingUsers.isEmpty()) return
            foldedUsers += pendingUsers.size - 1
            merged.add(mergeUnansweredUsers(pendingUsers))
            pendingUsers.clear()
        }
        for (msg in filtered) {
            if (msg.role == ChatRole.User) {
                pendingUsers.add(msg)
                continue
            }
            flushUsers()
            val last = merged.lastOrNull()
            if (last != null && last.role == ChatRole.Assistant) {
                val joinedText = listOf(last.text.trimWhiteSpace(), msg.text.trimWhiteSpace())
                    .filter { it.isNotEmpty() }
                    .joinToString("\n\n")
                merged[merged.size - 1] = last.copy(text = joinedText, attachments = last.attachments + msg.attachments)
            } else {
                merged.add(msg)
            }
        }
        flushUsers()
        return ContextSanitizeResult(merged, foldedUsers)
    }

    private fun mergeUnansweredUsers(run: List<ContextMessage>): ContextMessage {
        val latest = run.last()
        if (run.size == 1) return latest
        val earlierTexts = run.dropLast(1).map { it.text.trimWhiteSpace() }.filter { it.isNotEmpty() }.map(::escapeXml)
        val text = if (earlierTexts.isEmpty()) {
            latest.text
        } else {
            val envelope = "<$UNANSWERED_TAG>\n<note>$UNANSWERED_NOTE</note>\n" +
                earlierTexts.joinToString("\n\n") + "\n</$UNANSWERED_TAG>"
            if (latest.text.isEmpty()) envelope else envelope + "\n\n" + latest.text
        }
        return latest.copy(text = text, attachments = run.flatMap { it.attachments })
    }

    /** & -> &amp;, < -> &lt;, > -> &gt; in that order. */
    internal fun escapeXml(text: String): String =
        text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}
