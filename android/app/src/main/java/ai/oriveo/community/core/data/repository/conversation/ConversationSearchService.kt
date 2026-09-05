package ai.oriveo.community.core.data.repository.conversation

import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ConversationWithCount
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.util.dedupeByNormalizedId
import ai.oriveo.community.core.util.normalizeConversationIds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

/** Conversation search, split out of the repository to keep search rules in one place. */
internal class ConversationSearchService(
    private val conversationDao: ConversationDao,
) {
    fun search(query: String): Flow<List<Conversation>> =
        conversationDao.searchWithCount(query, LOCAL_PARTITION_ID)
            .map(::mapConversationRows)
            .flowOn(Dispatchers.Default)

    private fun mapConversationRows(rows: List<ConversationWithCount>): List<Conversation> =
        dedupeByNormalizedId(
            items = rows,
            idSelector = { it.entity.id },
            pickPreferred = { existing, incoming ->
                if (incoming.entity.updatedAt >= existing.entity.updatedAt) incoming else existing
            },
        ).map { normalizeConversationIds(it.entity.toDomain(messageCount = it.messageCount)) }
}
