package ai.oriveo.community.core.data.backup

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.model.CostFormatter
import java.util.Locale

class ConversationExporter(
    private val conversationDao: ConversationDao,
    private val messageDao: MessageDao,
    /** Locale used to format the non-USD part of the cost (the UI locale). */
    private val localeProvider: () -> Locale = { Locale.getDefault() },
) {

    suspend fun exportMarkdown(conversationId: String): String? {
        val accountId = LOCAL_PARTITION_ID
        val convEntity = conversationDao.getById(accountId, conversationId) ?: return null
        val messages = messageDao.getByConversation(accountId, conversationId).map { it.toDomain() }

        return buildString {
            appendLine("# ${convEntity.title}")
            appendLine()
            appendLine("Model: ${convEntity.modelID}")
            // The USD total and the non-USD totals are exported per currency, never added across currencies
            val costText = CostFormatter.formatParts(convEntity.toDomain().costParts, localeProvider())
            if (costText.isNotEmpty()) {
                appendLine("Estimated Cost: $costText")
            }
            appendLine()
            appendLine("---")
            appendLine()

            for (msg in messages) {
                val role = when (msg.role.name) {
                    "User" -> "**You**"
                    "Assistant" -> "**Assistant**"
                    else -> "**${msg.role.name}**"
                }
                appendLine("### $role")
                appendLine()
                appendLine(msg.text)
                appendLine()
            }
        }
    }
}
