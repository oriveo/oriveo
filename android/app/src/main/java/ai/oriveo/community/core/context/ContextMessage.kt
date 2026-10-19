package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole

/** History message as seen by the context pipeline (independent of the persisted ChatMessage). */
data class ContextMessage(
    val id: String,
    val role: ChatRole,
    val text: String,
    val state: ChatMessageState,
    val attachments: List<Attachment> = emptyList(),
)
