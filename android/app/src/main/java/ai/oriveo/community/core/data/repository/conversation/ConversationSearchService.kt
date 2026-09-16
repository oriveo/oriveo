package ai.oriveo.community.core.data.repository.conversation

import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ConversationWithCount
import ai.oriveo.community.core.data.search.ConversationFtsQuery
import ai.oriveo.community.core.data.search.ConversationSearchIndexer
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.util.dedupeByNormalizedId
import ai.oriveo.community.core.util.normalizeConversationIds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapConcat
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

/** Conversation search, split out of the repository to keep search rules in one place. */
internal class ConversationSearchService(
    private val conversationDao: ConversationDao,
    private val searchIndexer: ConversationSearchIndexer? = null,
) {
    /**
     * Searches conversations, with message counts.
     *
     * Message bodies go through FTS4 (CJK bigrams) while titles and preview text keep their
     * substring LIKE. A bounded slice of the pending-index queue is caught up first, so something
     * just said is immediately findable; the backlog of an upgraded database is filled in by the
     * background batches rather than waited on here.
     *
     * When the input holds nothing indexable (pure punctuation) the query falls back to titles and
     * preview text only, because an empty string handed to FTS4 raises a syntax error.
     */
    @OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
    fun search(query: String): Flow<List<Conversation>> {
        val ftsQuery = ConversationFtsQuery.build(query)
        return catchUpIndex().flatMapConcat { indexComplete ->
            val rows = when {
                // Pure punctuation: nothing to index against, so titles and preview text only.
                ftsQuery == null -> conversationDao.searchMetadataWithCount(query, LOCAL_PARTITION_ID)
                // Index not caught up yet (freshly upgraded database): better a slow LIKE than a
                // user who cannot find message bodies at all.
                !indexComplete -> conversationDao.searchPendingIndexWithCount(query, LOCAL_PARTITION_ID)
                else -> conversationDao.searchWithCount(query, ftsQuery, LOCAL_PARTITION_ID)
            }
            rows.map(::mapConversationRows)
        }.flowOn(Dispatchers.Default)
    }

    /**
     * Catches the index up, then reports whether it is complete before the query runs.
     *
     * With no indexer (the DAO-only constructor used by unit tests) the index counts as complete:
     * in that setup the DAO is a mock and the test decides which query it expects.
     */
    private fun catchUpIndex(): Flow<Boolean> = flow {
        emit(searchIndexer?.catchUpForSearch() ?: true)
    }

    private fun mapConversationRows(rows: List<ConversationWithCount>): List<Conversation> =
        dedupeByNormalizedId(
            items = rows,
            idSelector = { it.entity.id },
            pickPreferred = { existing, incoming ->
                if (incoming.entity.updatedAt >= existing.entity.updatedAt) incoming else existing
            },
        ).map { normalizeConversationIds(it.entity.toDomain(messageCount = it.messageCount)) }
}
