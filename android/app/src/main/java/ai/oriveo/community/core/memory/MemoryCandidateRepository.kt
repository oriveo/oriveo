package ai.oriveo.community.core.memory

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.context.MemoryCandidateAction
import ai.oriveo.community.core.context.MemoryCandidateContext
import ai.oriveo.community.core.context.MemoryCandidateEdit
import ai.oriveo.community.core.context.MemoryCandidateError
import ai.oriveo.community.core.context.MemoryCandidateSource
import ai.oriveo.community.core.context.MemoryCandidateStatus
import ai.oriveo.community.core.context.MemoryIntent
import ai.oriveo.community.core.context.MemoryIntentSuggestion
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItemScope
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryPropose
import ai.oriveo.community.core.context.MemoryProposeContext
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryScopeType
import ai.oriveo.community.core.context.MemorySensitivity
import ai.oriveo.community.core.context.MemorySourceType
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.dao.MemoryCandidateDao
import ai.oriveo.community.core.data.entity.MemoryCandidateEntity
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Result of a candidate operation: success carries the value, failure carries the memory-intent transition error. */
sealed interface MemoryCandidateResult<out T> {
    data class Ok<T>(val value: T) : MemoryCandidateResult<T>
    data class Failed(val error: MemoryCandidateError) : MemoryCandidateResult<Nothing>
}

/**
 * Local repository of memory candidates: stores only the current local partition and is not included in backups.
 * Keeps only pending and not-yet-expired rejected candidates; generate runs a sweep before writing and pending before reading to delete purged rows; accept / reject do not sweep first.
 * A candidate never becomes an item directly: only accept creates one, through [MemoryItemRepository.createFromDraft].
 * Writes are serialized, reads and writes run on [io]; time comes from the injectable [now] (milliseconds).
 */
class MemoryCandidateRepository(
    private val dao: MemoryCandidateDao,
    /** Item repository: accept creates items through it; undoing a chat memory chip also uses it to delete the item just created. */
    val items: MemoryItemRepository,
    private val now: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /** Local preferences holding the auto-suggest switch; null counts as on. */
    private val preferences: AppPreferencesRepository? = null,
) {
    private val writeMutex = Mutex()

    /** Whether auto-suggest is on for this account (a per-account local preference, on by default). */
    suspend fun autoSuggestEnabled(accountId: String): Boolean =
        preferences?.getMemoryAutoSuggestEnabled() ?: true

    /** Changes this account's auto-suggest switch: written locally only; turning it off does not delete existing pending candidates. */
    suspend fun setAutoSuggestEnabled(accountId: String, on: Boolean) {
        preferences?.setMemoryAutoSuggestEnabled(on)
    }

    /**
     * Judges one newly sent user sentence: when useMemory is off or classify's suggestion is not memory -> null, no row is read or deleted;
     * otherwise makeCandidate (autoSuggest reads this account's switch: when off, an implicit intent is skipped with auto_suggest_off, while an explicit "remember" request still works); a candidate is written and returned only when the decision is create. classify also runs on [io], so it does not hold the caller's thread.
     * records = all candidates of this partition (ascending by id), activeContents = bodies of the active / paused / conflicted items of this partition; the item table is not written.
     */
    @Suppress("LongParameterList")
    suspend fun generate(
        accountId: String,
        text: String,
        messageId: String,
        conversationId: String,
        folderId: String?,
        useMemory: Boolean,
        nowMs: Long = now(),
    ): MemoryCandidate? {
        if (!useMemory) return null
        return withContext(io) {
            val classification = MemoryIntent.classify(text)
            if (classification.suggestion != MemoryIntentSuggestion.MEMORY) return@withContext null
            val autoSuggest = autoSuggestEnabled(accountId)
            writeMutex.withLock {
                val activeContents = activeContents(accountId)
                val records = sweepLocked(accountId, activeContents, nowMs)
                val decision = MemoryIntent.makeCandidate(
                    classification,
                    MemoryCandidateContext(
                        conversationId = conversationId,
                        folderId = folderId,
                        messageId = messageId,
                        nowMs = nowMs,
                        activeContents = activeContents,
                        records = records,
                        autoSuggest = autoSuggest,
                    ),
                )
                val candidate = decision.candidate?.takeIf { decision.action == MemoryCandidateAction.CREATE }
                candidate?.also { dao.upsert(it.toEntity(accountId)) }
            }
        }
    }

    /**
     * One propose_memory call (memory-propose.v2 rule 4): same storage and same sweep as generate;
     * a candidate is written and returned only when the outcome is create, otherwise null; bad arguments do not throw either (the caller always answers the tool call with the fixed TOOL_RESULT).
     */
    @Suppress("LongParameterList")
    suspend fun propose(
        accountId: String,
        argumentsJson: String,
        priorInTurn: Int,
        userText: String,
        messageId: String,
        conversationId: String,
        folderId: String?,
        nowMs: Long = now(),
    ): MemoryCandidate? = withContext(io) {
        writeMutex.withLock {
            val activeContents = activeContents(accountId)
            val records = sweepLocked(accountId, activeContents, nowMs)
            val decision = MemoryPropose.propose(
                argumentsJson,
                MemoryProposeContext(
                    conversationId = conversationId,
                    folderId = folderId,
                    messageId = messageId,
                    nowMs = nowMs,
                    activeContents = activeContents,
                    records = records,
                    userText = userText,
                ),
                priorInTurn,
            )
            val candidate = decision.candidate?.takeIf { decision.action == MemoryCandidateAction.CREATE }
            candidate?.also { dao.upsert(it.toEntity(accountId)) }
        }
    }

    /**
     * Accept: no such row -> not_pending; an error from MemoryIntent.accept is returned as is (an expired candidate's row is deleted too);
     * on success the item is created through createFromDraft and the candidate row deleted: the delete is handed to the item repository as `alongside`, run in the same transaction under its write lock
     * (this method opens no transaction of its own, so the lock order never inverts between a transaction and the item write lock); any failure rolls everything back (the exception is rethrown); returns the new item.
     */
    suspend fun accept(
        accountId: String,
        id: String,
        edit: MemoryCandidateEdit? = null,
        nowMs: Long = now(),
    ): MemoryCandidateResult<MemoryItem> = withContext(io) {
        writeMutex.withLock {
            val record = read(accountId, id) ?: return@withLock MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING)
            val transition = MemoryIntent.accept(record, edit, nowMs)
            val error = transition.error
            val draft = transition.item
            when {
                error != null -> {
                    if (error == MemoryCandidateError.EXPIRED) dao.delete(accountId, record.id)
                    MemoryCandidateResult.Failed(error)
                }
                draft == null -> MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING)
                else -> MemoryCandidateResult.Ok(
                    items.createFromDraft(accountId, draft) { dao.delete(accountId, record.id) },
                )
            }
        }
    }

    /** Reject: stores the MemoryIntent.reject result (only the fingerprint is kept, so the same sentence is not proposed again within the rejection window); no such row -> not_pending. */
    suspend fun reject(accountId: String, id: String, nowMs: Long = now()): MemoryCandidateResult<MemoryCandidate> =
        withContext(io) {
            writeMutex.withLock {
                val record = read(accountId, id) ?: return@withLock MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING)
                val transition = MemoryIntent.reject(record, nowMs)
                val error = transition.error
                val rejected = transition.record
                when {
                    error != null -> MemoryCandidateResult.Failed(error)
                    rejected == null -> MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING)
                    else -> {
                        dao.upsert(rejected.toEntity(accountId))
                        MemoryCandidateResult.Ok(rejected)
                    }
                }
            }
        }

    /** Candidates awaiting confirmation: sweeps first, then orders by createdAtMs descending, ties by id ascending. */
    suspend fun pending(accountId: String, nowMs: Long = now()): List<MemoryCandidate> = withContext(io) {
        writeMutex.withLock {
            sweepLocked(accountId, activeContents(accountId), nowMs)
                .filter { it.status == MemoryCandidateStatus.PENDING }
                .sortedWith(compareByDescending<MemoryCandidate> { it.createdAtMs }.thenBy { it.id })
        }
    }

    /** Reads one candidate (no sweep). */
    suspend fun get(accountId: String, id: String): MemoryCandidate? = withContext(io) { read(accountId, id) }

    private suspend fun read(accountId: String, id: String): MemoryCandidate? = dao.get(accountId, id)?.toCandidate()

    /** Bodies of the active / paused / conflicted items of this partition (superseded / expired / deleted ones do not count). */
    private suspend fun activeContents(accountId: String): List<String> =
        items.list(accountId).filter { it.status in ACTIVE_STATUSES }.map { it.content }

    /** Deletes the rows the sweep judges purged (rows that cannot be read are cleared too) and returns the remaining candidates. */
    private suspend fun sweepLocked(accountId: String, activeContents: List<String>, nowMs: Long): List<MemoryCandidate> {
        val rows = dao.list(accountId)
        val decoded = rows.mapNotNull { row -> row.toCandidate()?.let { row.id to it } }
        val unreadable = rows.map { it.id }.toSet() - decoded.map { it.first }.toSet()
        val records = decoded.map { it.second }
        val purged = MemoryIntent.sweep(records, activeContents, nowMs).purgedIds.toSet()
        (unreadable + purged).forEach { dao.delete(accountId, it) }
        return records.filter { it.id !in purged }
    }

    private companion object {
        val ACTIVE_STATUSES = setOf(MemoryStatus.ACTIVE, MemoryStatus.PAUSED, MemoryStatus.CONFLICTED)
    }
}

private val candidateJson = Json { ignoreUnknownKeys = true }

private fun MemoryCandidate.toEntity(accountId: String): MemoryCandidateEntity = MemoryCandidateEntity(
    accountId = accountId,
    id = id,
    status = status.wire,
    payload = candidateJson.encodeToString(JsonObject.serializer(), toJson()),
)

private fun MemoryCandidate.toJson(): JsonObject = buildJsonObject {
    put("id", id)
    put("status", status.wire)
    put("proposedLayer", proposedLayer.wire)
    put("proposedKind", proposedKind.wire)
    put("content", content)
    put(
        "scope",
        buildJsonObject {
            put("type", scope.type.wire)
            put("id", scope.id)
        },
    )
    put(
        "source",
        buildJsonObject {
            put("type", source.type.wire)
            put("conversationId", source.conversationId)
            put("messageIds", JsonArray(source.messageIds.map(::JsonPrimitive)))
            put("observedAtMs", source.observedAtMs)
        },
    )
    put("sensitivity", sensitivity.wire)
    put("confidence", confidence)
    put("fingerprint", fingerprint)
    put("createdAtMs", createdAtMs)
    put("expiresAtMs", expiresAtMs)
    put("resolvedAtMs", resolvedAtMs)
}

/** Returns null for rows that cannot be read (broken JSON, unknown enum); the sweep clears them. */
private fun MemoryCandidateEntity.toCandidate(): MemoryCandidate? = runCatching {
    val o = candidateJson.parseToJsonElement(payload).jsonObject
    val scope = o.getValue("scope").jsonObject
    val source = o.getValue("source").jsonObject
    MemoryCandidate(
        id = o.string("id") ?: id,
        status = MemoryCandidateStatus.fromWire(o.string("status") ?: status) ?: return null,
        proposedLayer = MemoryLayer.fromWire(o.string("proposedLayer").orEmpty()) ?: return null,
        proposedKind = MemoryKind.fromWire(o.string("proposedKind").orEmpty()) ?: return null,
        content = o.string("content").orEmpty(),
        scope = MemoryItemScope(
            type = MemoryScopeType.fromWire(scope.string("type").orEmpty()) ?: return null,
            id = scope.string("id"),
        ),
        source = MemoryCandidateSource(
            type = MemorySourceType.fromWire(source.string("type").orEmpty()) ?: return null,
            conversationId = source.string("conversationId"),
            messageIds = source["messageIds"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty(),
            observedAtMs = source.nullableLong("observedAtMs"),
        ),
        sensitivity = MemorySensitivity.fromWire(o.string("sensitivity").orEmpty()) ?: return null,
        confidence = o.getValue("confidence").jsonPrimitive.double,
        fingerprint = o.string("fingerprint") ?: return null,
        createdAtMs = o.getValue("createdAtMs").jsonPrimitive.long,
        expiresAtMs = o.getValue("expiresAtMs").jsonPrimitive.long,
        resolvedAtMs = o.nullableLong("resolvedAtMs"),
    )
}.getOrNull()

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

private fun JsonObject.nullableLong(key: String): Long? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.longOrNull
