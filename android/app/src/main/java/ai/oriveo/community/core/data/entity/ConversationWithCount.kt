package ai.oriveo.community.core.data.entity

import androidx.room.Embedded

data class ConversationWithCount(
    @Embedded val entity: ConversationEntity,
    val messageCount: Int,
)
