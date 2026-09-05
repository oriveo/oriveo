package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import java.text.DateFormat
import java.util.Date

/** Renders a conversation as a Markdown document for export. */
object ChatExport {
    fun markdown(
        conversation: Conversation,
        formatter: DateFormat = defaultTimestampFormatter(),
    ): String {
        val lines = mutableListOf<String>()
        val title = conversation.title.trim().ifEmpty { "Untitled" }
        lines += "# $title"
        lines += ""

        lines += "*${formatter.format(Date(conversation.updatedAt))}*"
        lines += ""

        for (msg in conversation.messages) {
            val role = if (msg.role == ChatRole.User) "User" else "Assistant"
            lines += "## $role"
            lines += ""
            lines += msg.text
            lines += ""

            if (msg.role == ChatRole.Assistant && msg.modelName.isNotEmpty()) {
                val providerSuffix = if (msg.providerName.isEmpty()) "" else " (${msg.providerName})"
                lines += "*Model: ${msg.modelName}$providerSuffix*"
                lines += ""
            }
        }

        return lines.joinToString("\n")
    }

    fun sanitizeFilename(raw: String): String {
        val invalid = setOf('/', '\\', '?', '%', '*', ':', '|', '"', '<', '>')
        val cleaned = raw.map { if (it in invalid) '-' else it }.joinToString("")
        val trimmed = cleaned.trim()
        val fallback = trimmed.ifEmpty { "conversation" }
        return fallback.take(100)
    }

    fun defaultTimestampFormatter(): DateFormat =
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
}
