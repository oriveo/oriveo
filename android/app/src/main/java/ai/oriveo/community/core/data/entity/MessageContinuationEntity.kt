package ai.oriveo.community.core.data.entity

import androidx.room.Entity
import androidx.room.Index


@Entity(
    tableName = "message_continuations",
    primaryKeys = ["accountId", "messageId"],
    indices = [
        Index(value = ["messageId", "accountId"]),
        Index(value = ["accountId", "conversationId"]),
    ],
)
data class MessageContinuationEntity(
    val accountId: String,
    val messageId: String,
    val conversationId: String,
    val kind: String = "tool_loop",
    /** Every opaque continuation is valid only while this process token still matches. */
    val processSessionToken: String? = null,
    /** Opaque JSON lives only in the separately excluded local continuation database. */
    val stateJson: String,
    val interrupted: Boolean = false,
    val updatedAt: Long,
)
