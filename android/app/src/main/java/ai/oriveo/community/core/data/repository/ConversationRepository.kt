package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.MessageContinuationDao
import ai.oriveo.community.core.data.repository.chat.MessageWindowLoader
import ai.oriveo.community.core.data.repository.conversation.ConversationSearchService
import kotlinx.serialization.encodeToString
import ai.oriveo.community.core.data.repository.conversation.ConversationUsageAnalytics
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.computeConversationActivityAt
import ai.oriveo.community.core.model.deriveConversationMetadata
import ai.oriveo.community.core.model.lastDeliveredMessage
import ai.oriveo.community.core.model.makeConversationPreviewText
import ai.oriveo.community.core.usage.MonthlyCostSummary
import ai.oriveo.community.core.usage.ProviderUsageSummary
import ai.oriveo.community.core.util.dedupeByNormalizedId
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.normalizeConversationIds
import ai.oriveo.community.core.util.normalizeMessageIds
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext

/** Reads and writes conversations and the messages inside them. */
class ConversationRepository(
    private val conversationDao: ConversationDao,
    private val messageDao: MessageDao,
    private val runInTransaction: suspend (suspend () -> Unit) -> Unit = { block -> block() },
    private val onAssistantDelivered: suspend (String) -> Unit = {},
    private val continuationDao: MessageContinuationDao? = null,
) {
    private val searchService = ConversationSearchService(conversationDao)
    private val usageAnalytics = ConversationUsageAnalytics(messageDao)
    private val pinnedNoteIdsJson =
        kotlinx.serialization.json.Json { ignoreUnknownKeys = true; coerceInputValues = true }

    private companion object {
        /** Pinning more than three notes crowds out the conversation itself in the prompt. */
        const val MAX_PINNED_NOTES = 3
        /** Leaves headroom below SQLite's traditional 999 bind-variable ceiling. */
        const val CONTINUATION_DELETE_CHUNK_SIZE = 500
    }

    private fun mapConversationRows(rows: List<ai.oriveo.community.core.data.entity.ConversationWithCount>): List<Conversation> =
        dedupeByNormalizedId(
            items = rows,
            idSelector = { it.entity.id },
            pickPreferred = { existing, incoming ->
                if (incoming.entity.updatedAt >= existing.entity.updatedAt) incoming else existing
            },
        ).map { normalizeConversationIds(it.entity.toDomain(messageCount = it.messageCount)) }

    private val accountId: String get() = LOCAL_PARTITION_ID

    /**
     * Reads a conversation's messages, or null if the read itself failed.
     *
     * A single oversized row makes SQLite refuse the whole query. That has to be contained here:
     * the callers run in scopes with no exception handler, so letting it escape turns one bad row
     * into a crash on every attempt to open the conversation. Null lets the caller show an empty
     * conversation with a warning instead.
     */
    private suspend fun readMessagesOrNull(
        conversationId: String,
        where: String,
        scopedAccountId: String = accountId,
    ): List<ai.oriveo.community.core.data.entity.MessageEntity>? =
        try {
            messageDao.getByConversation(scopedAccountId, conversationId)
        } catch (e: android.database.sqlite.SQLiteException) {
            android.util.Log.e("ConversationRepository", "corrupt row read at $where: ${e.localizedMessage}", e)
            null
        }

    /**
     * Marks messages left in Generating as Interrupted, so a stream killed by process death or a
     * suspended socket shows a retry affordance instead of a spinner that never stops.
     */
    suspend fun sanitizeStaleGenerating(): Int = messageDao.sanitizeStaleGenerating()

    /** Checkpoints the visible text of a message that is still generating. */
    suspend fun updatePartialText(messageId: String, text: String): Int =
        messageDao.updatePartialText(accountId, normalizeUuid(messageId), text)

    /** The reasoning-text counterpart to [updatePartialText]. */
    suspend fun updatePartialReasoning(messageId: String, reasoningText: String): Int =
        messageDao.updatePartialReasoning(accountId, normalizeUuid(messageId), reasoningText)

    suspend fun updateMessageTokenUsage(
        messageId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
    ): Int = messageDao.updateMessageTokenUsage(
        accountId = accountId,
        id = normalizeUuid(messageId),
        inputTokens = inputTokens,
        outputTokens = outputTokens,
        cacheReadTokens = cacheReadTokens,
        cacheWriteTokens = cacheWriteTokens,
    )

    private suspend fun refreshConversationMetadata(
        conversationId: String,
        updatedAt: Long? = null,
        isDraft: Boolean? = null,
        scopedAccountId: String = accountId,
    ): Conversation? {
        val entity = conversationDao.getById(scopedAccountId, conversationId) ?: return null

        val lastDelivered = messageDao.lastDelivered(scopedAccountId, conversationId)
            ?.let { normalizeMessageIds(it.toDomain()) }
        val lastDeliveredUser = messageDao.lastDeliveredUser(scopedAccountId, conversationId)
            ?.let { normalizeMessageIds(it.toDomain()) }
        val messages = listOfNotNull(lastDeliveredUser, lastDelivered)
        val metadata = deriveConversationMetadata(entity.toDomain(messages), messages)
        val resolvedUpdatedAt = updatedAt
            ?: computeConversationActivityAt(messages, entity.createdAt)
        val updatedEntity = entity.copy(
            title = metadata.title,
            previewText = metadata.previewText,
            updatedAt = resolvedUpdatedAt,
            isDraft = isDraft ?: entity.isDraft,
        )
        conversationDao.update(updatedEntity)
        return normalizeConversationIds(updatedEntity.toDomain(messages))
    }

    fun observeMonthlyCostSummary(visibleProviderLimit: Int = 3): Flow<MonthlyCostSummary> =
        usageAnalytics.observeMonthlyCostSummary(visibleProviderLimit)

    suspend fun currentMonthlyCostTotal(): Double = usageAnalytics.currentMonthlyCostTotal()

    fun observeMonthlyCostByConversationProvider(): Flow<Map<String, Double>> =
        usageAnalytics.observeMonthlyCostByConversationProvider()

    fun observeProviderLocalUsageSummary(
        provider: ai.oriveo.community.core.model.Provider,
        visibleModelLimit: Int = 3,
    ): Flow<ProviderUsageSummary> = usageAnalytics.observeProviderLocalUsageSummary(provider, visibleModelLimit)

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeAll(): Flow<List<Conversation>> =
        conversationDao.observeAllWithCount(accountId).map(::mapConversationRows).distinctUntilChanged()

        .flowOn(Dispatchers.Default)

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeCount(): Flow<Int> =
        conversationDao.observeCount(accountId)

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeHasAnyWithMessages(): Flow<Boolean> =
        conversationDao.observeHasAnyWithMessages(accountId)

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeUngroupedHomeConversations(
        recentStartMillis: Long,
        earlierLimit: Int,
    ): Flow<List<Conversation>> =
        combine(
            conversationDao.observeUngroupedRecentWithCount(accountId, recentStartMillis),
            conversationDao.observeUngroupedEarlierWithCount(accountId, recentStartMillis, earlierLimit),
        ) { recentRows, earlierRows ->
            mapConversationRows(recentRows + earlierRows)
        }.flowOn(Dispatchers.Default)

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeUngroupedEarlierCount(recentStartMillis: Long): Flow<Int> =
        conversationDao.observeUngroupedEarlierCount(accountId, recentStartMillis)

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeMetadata(id: String): Flow<Conversation?> {
        val normalizedId = normalizeUuid(id)
        return conversationDao.observeById(accountId, normalizedId).map { entity -> entity?.let { normalizeConversationIds(it.toDomain(emptyList())) } }
            .distinctUntilChanged { old, new ->
                old?.metadataFingerprint() == new?.metadataFingerprint()
            }
            .flowOn(Dispatchers.Default)
    }

    fun createMessageWindowLoader(): MessageWindowLoader =
        MessageWindowLoader(messageDao)

    suspend fun getWithLatestMessageWindow(
        id: String,
        windowSize: Int = MessageWindowLoader.WINDOW_SIZE_DEFAULT,
    ): Conversation? {
        val normalizedId = normalizeUuid(id)
        val scopedAccountId = accountId
        val entity = conversationDao.getById(scopedAccountId, normalizedId) ?: return null
        val messageEntities = messageDao.fetchLatestMessageWindow(scopedAccountId, normalizedId, windowSize)
        return withContext(Dispatchers.Default) {
            val messages = messageEntities.map { normalizeMessageIds(it.toDomain()) }
            normalizeConversationIds(entity.toDomain(messages))
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeWithMessages(id: String): Flow<Conversation?> {
        val normalizedId = normalizeUuid(id)
        return combine(
            conversationDao.observeById(accountId, normalizedId),
            messageDao.observeByConversation(accountId, normalizedId),
        ) { convEntity, msgEntities ->
            convEntity to msgEntities
        }.map { (convEntity, msgEntities) ->
            val messages = dedupeByNormalizedId(
                items = msgEntities,
                idSelector = { it.id },
                pickPreferred = { existing, incoming ->
                    if (
                        incoming.sortOrder > existing.sortOrder ||
                        (incoming.sortOrder == existing.sortOrder &&
                            (incoming.createdAt ?: 0L) >= (existing.createdAt ?: 0L))
                    ) {
                        incoming
                    } else {
                        existing
                    }
                },
            ).map { normalizeMessageIds(it.toDomain()) }
            convEntity?.let { normalizeConversationIds(it.toDomain(messages)) }
        }.distinctUntilChanged { old, new ->
            old?.streamFingerprint() == new?.streamFingerprint()
        }

        .flowOn(Dispatchers.Default)
    }

    suspend fun getWithMessages(id: String): Conversation? {
        val normalizedId = normalizeUuid(id)
        val scopedAccountId = accountId
        val conversation = conversationDao.getById(scopedAccountId, normalizedId) ?: return null

        val messageEntities = readMessagesOrNull(normalizedId, "getWithMessages", scopedAccountId) ?: return null
        return withContext(Dispatchers.Default) {
            val messages = dedupeByNormalizedId(
                items = messageEntities,
                idSelector = { it.id },
                pickPreferred = { existing, incoming ->
                    if (
                        incoming.sortOrder > existing.sortOrder ||
                        (incoming.sortOrder == existing.sortOrder &&
                            (incoming.createdAt ?: 0L) >= (existing.createdAt ?: 0L))
                    ) {
                        incoming
                    } else {
                        existing
                    }
                },
            ).map { normalizeMessageIds(it.toDomain()) }
            normalizeConversationIds(conversation.toDomain(messages))
        }
    }

    fun search(query: String): Flow<List<Conversation>> = searchService.search(query)

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeMessageCount(providerId: String): Flow<Int> =
        messageDao.observeCountByProvider(normalizeUuid(providerId), accountId)

    suspend fun create(
        providerID: String,
        providerKind: ProviderKind,
        modelID: String,
        title: String = "New Chat",
        folderID: String? = null,
        skillId: String? = null,
        useMemory: Boolean = true,
    ): Conversation {
        val scopedAccountId = accountId

        val now = System.currentTimeMillis()
        val conversation = Conversation(
            id = generateUuidString(),
            title = title,
            providerID = normalizeUuid(providerID),
            providerKind = providerKind,
            modelID = modelID,
            isDraft = false,
            folderID = folderID?.let(::normalizeUuid),
            skillId = skillId,
            useMemory = useMemory,
            createdAt = now,
            updatedAt = now,
        )
        conversationDao.upsert(conversation.toEntity(scopedAccountId))
        return normalizeConversationIds(conversation)
    }

    suspend fun createDraft(
        providerID: String,
        providerKind: ProviderKind,
        modelID: String,
        title: String = "New Chat",
        folderID: String? = null,
        skillId: String? = null,
        useMemory: Boolean = true,
    ): Conversation {
        val scopedAccountId = accountId

        val now = System.currentTimeMillis()
        val conversation = Conversation(
            id = generateUuidString(),
            title = title,
            providerID = normalizeUuid(providerID),
            providerKind = providerKind,
            modelID = modelID,
            isDraft = true,
            folderID = folderID?.let(::normalizeUuid),
            skillId = skillId,
            useMemory = useMemory,
            createdAt = now,
            updatedAt = now,
        )
        conversationDao.upsert(conversation.toEntity(scopedAccountId))
        return normalizeConversationIds(conversation)
    }

    suspend fun findOrCreateDraft(
        providerID: String,
        providerKind: ProviderKind,
        modelID: String,
    ): Conversation {
        val scopedAccountId = accountId
        val normalizedProviderId = normalizeUuid(providerID)

        val emptyDraft = conversationDao.findFirstEmptyDraft(scopedAccountId)
        if (emptyDraft != null) {
            val updated = emptyDraft.copy(
                providerID = normalizedProviderId,
                providerKind = providerKind.name,
                modelID = modelID,
                updatedAt = System.currentTimeMillis(),
            )
            conversationDao.update(updated)
            return normalizeConversationIds(updated.toDomain())
        }

        return create(normalizedProviderId, providerKind, modelID)
    }

    suspend fun addMessage(conversationId: String, message: ChatMessage) {
        val scopedAccountId = accountId
        val normalizedConversationId = normalizeUuid(conversationId)
        val normalizedMessage = normalizeMessageIds(message)
        val currentMax = messageDao.maxSortOrder(scopedAccountId, normalizedConversationId)
        val nextOrder = (currentMax ?: -1) + 1
        try {
            messageDao.upsert(normalizedMessage.toEntity(scopedAccountId, normalizedConversationId, nextOrder))
        } catch (_: android.database.sqlite.SQLiteConstraintException) {

            return
        }

        refreshConversationMetadata(
            conversationId = normalizedConversationId,
            isDraft = false,
            scopedAccountId = scopedAccountId,
        )

    }

    suspend fun hydrateRemoteMessageWindowAround(
        conversationId: String,
        messageId: String,
        windowSize: Int = MessageWindowLoader.WINDOW_SIZE_DEFAULT,
    ): Boolean = false

    suspend fun updateMessage(conversationId: String, message: ChatMessage) {
        val scopedAccountId = accountId
        val normalizedConversationId = normalizeUuid(conversationId)
        val normalizedMessage = normalizeMessageIds(message)
        val existing = messageDao.getById(scopedAccountId, normalizedMessage.id)

        if (existing == null) return
        val order = existing.sortOrder
        try {
            messageDao.upsert(normalizedMessage.toEntity(scopedAccountId, normalizedConversationId, order))
        } catch (_: android.database.sqlite.SQLiteConstraintException) {

            return
        }
        val updatedConversation = refreshConversationMetadata(
            normalizedConversationId,
            scopedAccountId = scopedAccountId,
        )

        if (normalizedMessage.state == ChatMessageState.Delivered &&
            normalizedMessage.role == ChatRole.Assistant
        ) {

            val conversationCost = messageDao.sumDeliveredCost(
                accountId = scopedAccountId,
                conversationId = normalizedConversationId,
                minimumCostExclusive = CostFormatter.COST_EPSILON,
            )

            val pairedUser = if (updatedConversation != null) {
                messageDao.lastDeliveredUserBefore(scopedAccountId, normalizedConversationId, order)
                    ?.let { normalizeMessageIds(it.toDomain()) }
            } else {
                null
            }
            val deliveredCount = messageDao.countDeliveredByConversation(scopedAccountId, normalizedConversationId)

        }
    }

    suspend fun updateTitle(id: String, title: String, isCustom: Boolean = true) {
        val scopedAccountId = accountId
        val normalizedId = normalizeUuid(id)
        conversationDao.getById(scopedAccountId, normalizedId)?.let {
            conversationDao.update(it.copy(title = title, hasCustomTitle = isCustom))
        }

        if (isCustom) {
        }
    }

    suspend fun refreshCost(conversationId: String, scopedAccountId: String = accountId) {
        val normalizedId = normalizeUuid(conversationId)

        val newCost = messageDao.sumDeliveredCost(
            accountId = scopedAccountId,
            conversationId = normalizedId,
            minimumCostExclusive = CostFormatter.COST_EPSILON,
        )
        conversationDao.getById(scopedAccountId, normalizedId)?.let {
            conversationDao.update(it.copy(estimatedCost = newCost))
        }
    }

    suspend fun deleteMessagesAfter(conversationId: String, afterMessageId: String) {
        val scopedAccountId = accountId
        val normalizedConversationId = normalizeUuid(conversationId)

        val msg = try {
            messageDao.getById(scopedAccountId, normalizeUuid(afterMessageId))
        } catch (e: android.database.sqlite.SQLiteException) {
            android.util.Log.e("ConversationRepository", "corrupt row read at deleteMessagesAfter.getById", e)
            null
        } ?: return

        val allMsgs = readMessagesOrNull(normalizedConversationId, "deleteMessagesAfter", scopedAccountId)
        val deletedMsgs = allMsgs?.filter { it.sortOrder > msg.sortOrder }
        val deletedIDs = deletedMsgs?.map { normalizeUuid(it.id) }.orEmpty()
        val remainingLastMsg = allMsgs
            ?.filter { it.sortOrder <= msg.sortOrder }
            ?.maxByOrNull { it.sortOrder }
            ?.toDomain()

        if (allMsgs == null) continuationDao?.deleteForConversation(scopedAccountId, normalizedConversationId)
        else deletedIDs.chunked(CONTINUATION_DELETE_CHUNK_SIZE).forEach { ids ->
            continuationDao?.deleteMessages(scopedAccountId, ids)
        }
        messageDao.deleteAfterOrder(scopedAccountId, normalizedConversationId, msg.sortOrder)
        refreshConversationMetadata(normalizedConversationId, scopedAccountId = scopedAccountId)
        refreshCost(normalizedConversationId, scopedAccountId)

    }

    suspend fun deleteMessagesStartingAt(conversationId: String, startingMessageId: String) {
        val scopedAccountId = accountId
        val normalizedConversationId = normalizeUuid(conversationId)

        val msg = try {
            messageDao.getById(scopedAccountId, normalizeUuid(startingMessageId))
        } catch (e: android.database.sqlite.SQLiteException) {
            android.util.Log.e("ConversationRepository", "corrupt row read at deleteMessagesStartingAt.getById", e)
            null
        } ?: return
        val allMsgs = readMessagesOrNull(normalizedConversationId, "deleteMessagesStartingAt", scopedAccountId)
        val deletedMsgs = allMsgs?.filter { it.sortOrder >= msg.sortOrder }
        val deletedIDs = deletedMsgs?.map { normalizeUuid(it.id) }.orEmpty()
        val remainingLastMsg = allMsgs
            ?.filter { it.sortOrder < msg.sortOrder }
            ?.maxByOrNull { it.sortOrder }
            ?.toDomain()

        if (allMsgs == null) continuationDao?.deleteForConversation(scopedAccountId, normalizedConversationId)
        else deletedIDs.chunked(CONTINUATION_DELETE_CHUNK_SIZE).forEach { ids ->
            continuationDao?.deleteMessages(scopedAccountId, ids)
        }
        messageDao.deleteAfterOrder(scopedAccountId, normalizedConversationId, msg.sortOrder - 1)
        refreshConversationMetadata(normalizedConversationId, scopedAccountId = scopedAccountId)
        refreshCost(normalizedConversationId, scopedAccountId)
    }

    /** Deletes one conversation and everything it owns. */
    suspend fun delete(id: String) {
        val normalizedId = normalizeUuid(id)

        val scopedAccountId = accountId

        val entity = conversationDao.getById(scopedAccountId, normalizedId)

        val messages = readMessagesOrNull(normalizedId, "delete", scopedAccountId)
        val messageCount = if (entity != null) messages?.size ?: 0 else 0
        messages?.let { msgs ->
        }
        val ageHours = entity?.createdAt?.let {
            ((System.currentTimeMillis() - it).coerceAtLeast(0L) / 3_600_000L).toInt()
        } ?: 0

        continuationDao?.deleteForConversation(scopedAccountId, normalizedId)
        conversationDao.deleteById(scopedAccountId, normalizedId)
    }

    suspend fun rename(id: String, newTitle: String) {
        updateTitle(id, newTitle, isCustom = true)
    }

    suspend fun updateDraft(id: String, text: String) {
        val scopedAccountId = accountId
        val normalizedId = normalizeUuid(id)
        conversationDao.getById(scopedAccountId, normalizedId)?.let { entity ->
            val trimmed = text.trim()
            val messages = if (trimmed.isEmpty()) {

                readMessagesOrNull(normalizedId, "updateDraft", scopedAccountId)
                    ?.map { normalizeMessageIds(it.toDomain()) }
                    ?: emptyList()
            } else {
                emptyList()
            }
            val updatedEntity = entity.copy(
                draftText = text,
                previewText = if (trimmed.isNotEmpty()) {
                    if (trimmed.length > 100) trimmed.take(100) + "…" else trimmed
                } else {
                    lastDeliveredMessage(messages)?.let(::makeConversationPreviewText).orEmpty()
                },
                updatedAt = System.currentTimeMillis(),
            )
            conversationDao.update(updatedEntity)
        }
    }

    suspend fun updateProviderAndModel(
        id: String,
        providerId: String,
        providerKind: ProviderKind,
        modelId: String,
        relayKind: RelayKind? = null,
    ) {
        val scopedAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val normalizedProviderId = normalizeUuid(providerId)
        conversationDao.getById(scopedAccountId, normalizedId)?.let { entity ->
            conversationDao.update(
                entity.copy(
                    providerID = normalizedProviderId,
                    providerKind = providerKind.name,
                    modelID = modelId,
                ),
            )
        }

    }

    suspend fun moveToFolder(id: String, folderID: String?) {
        val scopedAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val normalizedFolderId = folderID?.let(::normalizeUuid)
        conversationDao.updateFolderID(scopedAccountId, normalizedId, normalizedFolderId)
    }

    suspend fun updateUseMemory(conversationId: String, useMemory: Boolean) {
        val scopedAccountId = accountId
        val normalizedId = normalizeUuid(conversationId)
        conversationDao.updateUseMemory(scopedAccountId, normalizedId, useMemory)
    }

    suspend fun pinNoteToConversation(conversationId: String, noteId: String): List<String>? {
        val scopedAccountId = accountId
        val normalizedConvId = normalizeUuid(conversationId)
        val normalizedNoteId = normalizeUuid(noteId)
        val existing = conversationDao.getById(scopedAccountId, normalizedConvId)?.toDomain() ?: return null
        val next = (existing.pinnedNoteIds + normalizedNoteId)
            .map(::normalizeUuid).distinct().takeLast(MAX_PINNED_NOTES)
        return applyPinnedNoteIds(scopedAccountId, existing, next)
    }

    suspend fun unpinNoteFromConversation(conversationId: String, noteId: String): List<String>? {
        val scopedAccountId = accountId
        val normalizedConvId = normalizeUuid(conversationId)
        val normalizedNoteId = normalizeUuid(noteId)
        val existing = conversationDao.getById(scopedAccountId, normalizedConvId)?.toDomain() ?: return null
        val next = existing.pinnedNoteIds.map(::normalizeUuid).filter { it != normalizedNoteId }
        return applyPinnedNoteIds(scopedAccountId, existing, next)
    }

    private suspend fun applyPinnedNoteIds(
        scopedAccountId: String,
        existing: Conversation,
        next: List<String>,
    ): List<String> {
        if (existing.pinnedNoteIds == next) return next
        val json = next.takeIf { it.isNotEmpty() }
            ?.let { pinnedNoteIdsJson.encodeToString(it) }
        conversationDao.updatePinnedNoteIds(scopedAccountId, normalizeUuid(existing.id), json)
        return next
    }

    suspend fun getRecentConversationsWithMessages(limit: Int = 5): List<Conversation> {
        val scopedAccountId = accountId

        val conversationIds = messageDao.getRecentConversationIdsWithMessages(scopedAccountId, limit)
        if (conversationIds.isEmpty()) return emptyList()

        return conversationIds.mapNotNull { id ->
            val entity = conversationDao.getById(scopedAccountId, id) ?: return@mapNotNull null

            val messages = readMessagesOrNull(id, "getRecentConversationsWithMessages", scopedAccountId)
                ?.map { normalizeMessageIds(it.toDomain()) }
                ?: return@mapNotNull null
            normalizeConversationIds(entity.toDomain(messages))
        }
    }

    suspend fun batchMoveToFolder(ids: Collection<String>, folderID: String?) {
        val scopedAccountId = accountId
        val normalizedFolderId = folderID?.let(::normalizeUuid)
        val normalizedIds = ids.map(::normalizeUuid).distinct()
        if (normalizedIds.isEmpty()) return

        if (normalizedFolderId != null) {
            conversationDao.batchUpdateFolderID(scopedAccountId, normalizedIds, normalizedFolderId)
        } else {
            conversationDao.batchClearFolderID(scopedAccountId, normalizedIds)
        }

    }

    suspend fun deleteMultiple(ids: List<String>) {
        val normalizedIds = ids.map(::normalizeUuid).toSet()
        if (normalizedIds.isEmpty()) return

        val scopedAccountId = accountId

        val deletedMessages = normalizedIds.flatMap { conversationId ->
            readMessagesOrNull(conversationId, "deleteMultiple", scopedAccountId)
                ?.map { normalizeMessageIds(it.toDomain()) }
                .orEmpty()
        }
        normalizedIds.forEach { continuationDao?.deleteForConversation(scopedAccountId, it) }
        conversationDao.deleteByIds(scopedAccountId, normalizedIds)
    }

    suspend fun autoTitle(conversationId: String) {
        val scopedAccountId = accountId
        val normalizedConversationId = normalizeUuid(conversationId)
        val conv = conversationDao.getById(scopedAccountId, normalizedConversationId) ?: return
        if (conv.hasCustomTitle) return

        val messages = messageDao.getByConversation(scopedAccountId, normalizedConversationId)
            .map { normalizeMessageIds(it.toDomain()) }
        val metadata = deriveConversationMetadata(conv.toDomain(messages), messages)
        conversationDao.update(conv.copy(title = metadata.title))
    }

    suspend fun hasData(): Boolean = conversationDao.countByAccount(accountId) > 0
}

private data class ConversationStreamFingerprint(
    val id: String,
    val title: String,
    val hasCustomTitle: Boolean,
    val providerID: String,
    val modelID: String,
    val previewTextHash: Int,
    val estimatedCostBits: Long,
    val isDraft: Boolean,
    val messageCount: Int,
    val draftTextHash: Int,
    val updatedAt: Long,
    val folderID: String?,
    val useMemory: Boolean,
    val messagesHash: Int,
)

private data class ConversationMetadataFingerprint(
    val id: String,
    val title: String,
    val hasCustomTitle: Boolean,
    val providerID: String,
    val providerKind: String,
    val modelID: String,
    val previewTextHash: Int,
    val estimatedCostBits: Long,
    val isDraft: Boolean,
    val messageCount: Int,
    val draftTextHash: Int,
    val updatedAt: Long,
    val folderID: String?,
    val skillId: String?,
    val useMemory: Boolean,
    val pinnedNoteIdsHash: Int,
)

private fun Conversation.metadataFingerprint(): ConversationMetadataFingerprint =
    ConversationMetadataFingerprint(
        id = id,
        title = title,
        hasCustomTitle = hasCustomTitle,
        providerID = providerID,
        providerKind = providerKind.name,
        modelID = modelID,
        previewTextHash = previewText.hashCode(),
        estimatedCostBits = estimatedCost.toBits(),
        isDraft = isDraft,
        messageCount = messageCount,
        draftTextHash = draftText.hashCode(),
        updatedAt = updatedAt,
        folderID = folderID,
        skillId = skillId,
        useMemory = useMemory,
        pinnedNoteIdsHash = pinnedNoteIds.hashCode(),
    )

private fun Conversation.streamFingerprint(): ConversationStreamFingerprint =
    ConversationStreamFingerprint(
        id = id,
        title = title,
        hasCustomTitle = hasCustomTitle,
        providerID = providerID,
        modelID = modelID,
        previewTextHash = previewText.hashCode(),
        estimatedCostBits = estimatedCost.toBits(),
        isDraft = isDraft,
        messageCount = messageCount,
        draftTextHash = draftText.hashCode(),
        updatedAt = updatedAt,
        folderID = folderID,
        useMemory = useMemory,
        messagesHash = messages.fold(1) { acc, message ->
            (acc * 31) + message.streamFingerprintHash()
        },
    )

private fun ChatMessage.streamFingerprintHash(): Int {
    var result = id.hashCode()
    result = 31 * result + role.hashCode()
    result = 31 * result + text.hashCode()
    result = 31 * result + (providerID?.hashCode() ?: 0)
    result = 31 * result + providerKind.hashCode()
    result = 31 * result + providerName.hashCode()
    result = 31 * result + (modelID?.hashCode() ?: 0)
    result = 31 * result + modelName.hashCode()
    result = 31 * result + (servedModelID?.hashCode() ?: 0)
    result = 31 * result + estimatedCost.toBits().hashCode()
    result = 31 * result + state.hashCode()
    result = 31 * result + (errorTitle?.hashCode() ?: 0)
    result = 31 * result + (errorDetail?.hashCode() ?: 0)
    result = 31 * result + (createdAt?.hashCode() ?: 0)
    result = 31 * result + (attachments?.fold(1) { acc, attachment ->
        (acc * 31) + attachment.streamFingerprintHash()
    } ?: 0)
    return result
}

private fun Attachment.streamFingerprintHash(): Int {
    var result = id.hashCode()
    result = 31 * result + kind.hashCode()
    result = 31 * result + fileName.hashCode()
    result = 31 * result + mimeType.hashCode()
    result = 31 * result + (localImageId?.hashCode() ?: 0)
    result = 31 * result + (base64Data?.length ?: 0)
    result = 31 * result + (thumbnailBase64?.length ?: 0)
    return result
}
