package ai.oriveo.community.core.data.repository.chat

import android.database.sqlite.SQLiteException
import android.util.Log
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.util.dedupeByNormalizedId
import ai.oriveo.community.core.util.normalizeMessageIds
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class MessageWindowLoader(
    private val messageDao: MessageDao,
    private val windowSize: Int = WINDOW_SIZE_DEFAULT,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val cpuDispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    private val accountId: String get() = LOCAL_PARTITION_ID

    data class MessageBoundary(val sortOrder: Int, val id: String)

    data class State(
        val conversationId: String? = null,
        val messages: List<ChatMessage> = emptyList(),
        val earliestBoundary: MessageBoundary? = null,
        val latestBoundary: MessageBoundary? = null,

        val hasMoreAbove: Boolean = false,

        val hasMoreBelow: Boolean = false,
        val isLoadingAbove: Boolean = false,
        val isLoadingBelow: Boolean = false,

        val isInitialLoading: Boolean = false,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private var observeJob: Job? = null
    private val mutex = Mutex()

    @Volatile
    private var observedConversationId: String? = null
    private var observeScope: CoroutineScope? = null
    private var observedAnchorMessageId: String? = null

    @OptIn(ExperimentalCoroutinesApi::class)
    fun bind(scope: CoroutineScope, conversationId: String) {
        val normalized = normalizeUuid(conversationId)
        if (observedConversationId == normalized && observedAnchorMessageId == null && observeJob?.isActive == true) return
        stop()
        observeScope = scope
        observedConversationId = normalized
        observedAnchorMessageId = null
        _state.value = State(conversationId = normalized, isInitialLoading = true)

        observeJob = scope.launch {
            messageDao.observeLatestMessageWindow(accountId, normalized, windowSize)
                .distinctUntilChanged()
                .catchCorruptRowRead("observeLatestMessageWindow")
                .collect { entities ->
                    if (observedConversationId != normalized) return@collect
                    handleObservedWindow(normalized, entities)
                }
        }
    }

    fun stop() {
        observeJob?.cancel()
        observeJob = null
        observedConversationId = null
        observeScope = null
        observedAnchorMessageId = null
        _state.value = State()
    }

    suspend fun extendUpward() {
        val convId = observedConversationId ?: return
        run {
            val current = _state.value
            if (current.conversationId != convId) return
            if (!current.hasMoreAbove || current.isLoadingAbove) return
            if (current.earliestBoundary == null) return
        }

        val boundary: MessageBoundary
        mutex.withLock {
            val latest = _state.value
            if (latest.conversationId != convId) return
            if (!latest.hasMoreAbove || latest.isLoadingAbove) return
            boundary = latest.earliestBoundary ?: return
            _state.value = latest.copy(isLoadingAbove = true)
        }

        try {
            val entities = withContext(ioDispatcher) {
                messageDao.fetchMessagesBefore(
                    accountId = accountId,
                    conversationId = convId,
                    boundarySortOrder = boundary.sortOrder,
                    boundaryId = boundary.id,
                    limit = windowSize,
                )
            }
            val canonicalEntities = withContext(cpuDispatcher) {
                canonicalizeMessageEntities(entities)
            }
            val newMessages = withContext(cpuDispatcher) {
                canonicalEntities.map { normalizeMessageIds(it.toDomain()) }
            }
            val newEarliest = canonicalEntities.firstOrNull()?.let {
                MessageBoundary(it.sortOrder, normalizeUuid(it.id))
            }
            val hasMoreAbove = if (newEarliest != null) {
                withContext(ioDispatcher) {
                    messageDao.existsBefore(accountId, convId, newEarliest.sortOrder, newEarliest.id)
                }
            } else {
                false
            }

            mutex.withLock {
                val now = _state.value
                if (now.conversationId != convId) return
                if (newMessages.isEmpty()) {
                    _state.value = now.copy(hasMoreAbove = false, isLoadingAbove = false)
                    return
                }
                val existingIds = now.messages.mapTo(HashSet(now.messages.size)) { it.id }
                val uniqueNewMessages = newMessages.filter { it.id !in existingIds }
                _state.value = now.copy(
                    messages = uniqueNewMessages + now.messages,
                    earliestBoundary = newEarliest ?: now.earliestBoundary,
                    hasMoreAbove = hasMoreAbove,
                    isLoadingAbove = false,
                )
            }
        } catch (t: Throwable) {

            withContext(NonCancellable) {
                mutex.withLock {
                    val now = _state.value
                    if (now.conversationId == convId) {
                        _state.value = now.copy(isLoadingAbove = false)
                    }
                }
            }

            if (isCorruptRowException(t)) {
                logCorruptRowRead("extendUpward", t)
                return
            }
            throw t
        }
    }

    suspend fun extendDownward() {
        val convId = observedConversationId ?: return
        run {
            val current = _state.value
            if (current.conversationId != convId) return
            if (!current.hasMoreBelow || current.isLoadingBelow) return
            if (current.latestBoundary == null) return
        }

        val boundary: MessageBoundary
        mutex.withLock {
            val latest = _state.value
            if (latest.conversationId != convId) return
            if (!latest.hasMoreBelow || latest.isLoadingBelow) return
            boundary = latest.latestBoundary ?: return
            _state.value = latest.copy(isLoadingBelow = true)
        }

        try {
            val entities = withContext(ioDispatcher) {
                messageDao.fetchMessagesAfter(
                    accountId = accountId,
                    conversationId = convId,
                    boundarySortOrder = boundary.sortOrder,
                    boundaryId = boundary.id,
                    limit = windowSize,
                )
            }
            val canonicalEntities = withContext(cpuDispatcher) {
                canonicalizeMessageEntities(entities)
            }
            val newMessages = withContext(cpuDispatcher) {
                canonicalEntities.map { normalizeMessageIds(it.toDomain()) }
            }
            val newLatest = canonicalEntities.lastOrNull()?.let {
                MessageBoundary(it.sortOrder, normalizeUuid(it.id))
            }
            val hasMoreBelow = if (newLatest != null) {
                withContext(ioDispatcher) {
                    messageDao.existsAfter(accountId, convId, newLatest.sortOrder, newLatest.id)
                }
            } else {
                false
            }

            mutex.withLock {
                val now = _state.value
                if (now.conversationId != convId) return
                if (newMessages.isEmpty()) {
                    _state.value = now.copy(hasMoreBelow = false, isLoadingBelow = false)
                    return
                }
                val existingIds = now.messages.mapTo(HashSet(now.messages.size)) { it.id }
                val uniqueNewMessages = newMessages.filter { it.id !in existingIds }
                _state.value = now.copy(
                    messages = now.messages + uniqueNewMessages,
                    latestBoundary = newLatest ?: now.latestBoundary,
                    hasMoreBelow = hasMoreBelow,
                    isLoadingBelow = false,
                )
            }
        } catch (t: Throwable) {
            withContext(NonCancellable) {
                mutex.withLock {
                    val now = _state.value
                    if (now.conversationId == convId) {
                        _state.value = now.copy(isLoadingBelow = false)
                    }
                }
            }
            if (isCorruptRowException(t)) {
                logCorruptRowRead("extendDownward", t)
                return
            }
            throw t
        }
    }

    suspend fun loadAroundMessage(conversationId: String, messageId: String): Boolean {
        val normalizedConversationId = normalizeUuid(conversationId)
        val normalizedMessageId = normalizeUuid(messageId)
        val scope = observeScope ?: return false

        val exists = withContext(ioDispatcher) {

            try {
                messageDao.getByIdForConversation(accountId, normalizedConversationId, normalizedMessageId) != null
            } catch (t: SQLiteException) {
                logCorruptRowRead("loadAroundMessage.getByIdForConversation", t)
                false
            }
        }
        if (!exists) return false

        mutex.withLock {
            if (
                observedConversationId == normalizedConversationId &&
                observedAnchorMessageId == normalizedMessageId &&
                observeJob?.isActive == true
            ) {
                return@withLock
            }
            observeJob?.cancel()
            observedConversationId = normalizedConversationId
            observedAnchorMessageId = normalizedMessageId
            _state.value = State(conversationId = normalizedConversationId, isInitialLoading = true)

            val beforeLimit = windowSize / 2
            val afterLimit = windowSize - beforeLimit - 1
            observeJob = scope.launch {
                messageDao.observeMessageWindowAround(
                    accountId = accountId,
                    conversationId = normalizedConversationId,
                    messageId = normalizedMessageId,
                    beforeLimit = beforeLimit,
                    afterLimit = afterLimit,
                )
                    .distinctUntilChanged()
                    .catchCorruptRowRead("observeMessageWindowAround")
                    .collect { entities ->
                        if (
                            observedConversationId != normalizedConversationId ||
                            observedAnchorMessageId != normalizedMessageId
                        ) {
                            return@collect
                        }
                        handleObservedWindow(normalizedConversationId, entities)
                    }
            }
        }
        return true
    }

    private suspend fun handleObservedWindow(conversationId: String, entities: List<MessageEntity>) {
        val canonicalEntities = withContext(cpuDispatcher) {
            canonicalizeMessageEntities(entities)
        }
        val messages = withContext(cpuDispatcher) {
            canonicalEntities.map { normalizeMessageIds(it.toDomain()) }
        }
        val earliest = canonicalEntities.firstOrNull()?.let {
            MessageBoundary(it.sortOrder, normalizeUuid(it.id))
        }
        val latest = canonicalEntities.lastOrNull()?.let {
            MessageBoundary(it.sortOrder, normalizeUuid(it.id))
        }
        val snapshotHasMoreAbove = if (earliest != null) {
            withContext(ioDispatcher) {
                messageDao.existsBefore(accountId, conversationId, earliest.sortOrder, earliest.id)
            }
        } else {
            false
        }
        val snapshotHasMoreBelow = if (latest != null) {
            withContext(ioDispatcher) {
                messageDao.existsAfter(accountId, conversationId, latest.sortOrder, latest.id)
            }
        } else {
            false
        }

        mutex.withLock {
            if (observedConversationId != conversationId) return
            applySnapshot(
                conversationId = conversationId,
                snapshotMessages = messages,
                snapshotEarliest = earliest,
                snapshotLatest = latest,
                snapshotHasMoreAbove = snapshotHasMoreAbove,
                snapshotHasMoreBelow = snapshotHasMoreBelow,
            )
        }
    }

    private fun applySnapshot(
        conversationId: String,
        snapshotMessages: List<ChatMessage>,
        snapshotEarliest: MessageBoundary?,
        snapshotLatest: MessageBoundary?,
        snapshotHasMoreAbove: Boolean,
        snapshotHasMoreBelow: Boolean,
    ) {
        val current = _state.value
        if (current.conversationId != conversationId) return

        if (observedAnchorMessageId != null) {
            _state.value = current.copy(
                messages = snapshotMessages,
                earliestBoundary = snapshotEarliest,
                latestBoundary = snapshotLatest,
                hasMoreAbove = snapshotHasMoreAbove,
                hasMoreBelow = snapshotHasMoreBelow,
                isInitialLoading = false,
            )
            return
        }

        if (current.messages.isEmpty()) {
            _state.value = current.copy(
                messages = snapshotMessages,
                earliestBoundary = snapshotEarliest,
                latestBoundary = snapshotLatest,
                hasMoreAbove = snapshotHasMoreAbove,
                hasMoreBelow = snapshotHasMoreBelow,
                isInitialLoading = false,
            )
            return
        }

        if (snapshotMessages.isEmpty()) {
            _state.value = current.copy(
                messages = emptyList(),
                earliestBoundary = null,
                latestBoundary = null,
                hasMoreAbove = false,
                hasMoreBelow = false,
                isInitialLoading = false,
            )
            return
        }

        val headId = snapshotMessages.first().id
        val cutIndex = current.messages.indexOfFirst { it.id == headId }
        val merged: List<ChatMessage>
        val keepExtension: Boolean
        if (cutIndex >= 0) {
            merged = mergePrefixWithSnapshot(current.messages, cutIndex, snapshotMessages)
            keepExtension = cutIndex > 0
        } else {
            val alignedIndex = findSnapshotAlignmentIndex(snapshotMessages, current.messages)
            if (alignedIndex != null) {
                merged = mergePrefixWithSnapshot(current.messages, alignedIndex, snapshotMessages)
                keepExtension = true
            } else {

                _state.value = current.copy(
                    messages = snapshotMessages,
                    earliestBoundary = snapshotEarliest,
                    latestBoundary = snapshotLatest,
                    hasMoreAbove = snapshotHasMoreAbove,
                    hasMoreBelow = snapshotHasMoreBelow,
                    isInitialLoading = false,
                )
                return
            }
        }

        val mergedEarliest = if (keepExtension) current.earliestBoundary else snapshotEarliest
        val mergedHasMoreAbove = if (keepExtension) current.hasMoreAbove else snapshotHasMoreAbove
        val mergedMessages = if (merged == current.messages) current.messages else merged

        _state.value = current.copy(
            messages = mergedMessages,
            earliestBoundary = mergedEarliest,
            latestBoundary = snapshotLatest,
            hasMoreAbove = mergedHasMoreAbove,
            hasMoreBelow = snapshotHasMoreBelow,
            isInitialLoading = false,
        )
    }

    private fun mergePrefixWithSnapshot(
        existing: List<ChatMessage>,
        cutIndex: Int,
        snapshotMessages: List<ChatMessage>,
    ): List<ChatMessage> {
        if (cutIndex <= 0) return snapshotMessages
        val prefix = existing.subList(0, cutIndex)
        val snapshotIds = snapshotMessages.mapTo(HashSet(snapshotMessages.size)) { it.id }
        val deduped = if (prefix.any { it.id in snapshotIds }) {
            prefix.filter { it.id !in snapshotIds }
        } else {
            prefix
        }
        return deduped + snapshotMessages
    }

    private fun findSnapshotAlignmentIndex(
        snapshot: List<ChatMessage>,
        existing: List<ChatMessage>,
    ): Int? {
        val probeCount = minOf(snapshot.size, SNAPSHOT_ALIGNMENT_PROBE_LIMIT)
        if (probeCount <= 1) return null
        val idToIndex = HashMap<String, Int>(existing.size)
        existing.forEachIndexed { idx, msg -> idToIndex[msg.id] = idx }
        for (i in 1 until probeCount) {
            val idx = idToIndex[snapshot[i].id]
            if (idx != null) return idx
        }
        return null
    }

    companion object {

        const val WINDOW_SIZE_DEFAULT = 60

        const val SNAPSHOT_ALIGNMENT_PROBE_LIMIT = 16
    }
}

private fun canonicalizeMessageEntities(entities: List<MessageEntity>): List<MessageEntity> =
    dedupeByNormalizedId(
        items = entities,
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
    ).sortedWith(compareBy({ it.sortOrder }, { normalizeUuid(it.id) }))

private fun isCorruptRowException(t: Throwable): Boolean = t is SQLiteException

private fun logCorruptRowRead(where: String, t: Throwable) {
    Log.e("MessageWindowLoader", "corrupt row read at $where: ${t.localizedMessage}", t)
    runCatching {
    }
}

private fun <T> kotlinx.coroutines.flow.Flow<T>.catchCorruptRowRead(where: String): kotlinx.coroutines.flow.Flow<T> =
    catch { t ->
        if (isCorruptRowException(t)) {
            logCorruptRowRead(where, t)
        } else {
            throw t
        }
    }
