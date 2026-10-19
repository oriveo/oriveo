package ai.oriveo.community.core.memory

import android.content.Context
import androidx.room.Room
import androidx.room.withTransaction
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.context.MemoryCandidateEdit
import ai.oriveo.community.core.context.MemoryCandidateError
import ai.oriveo.community.core.context.MemoryCandidateStatus
import ai.oriveo.community.core.context.MemoryIntent
import ai.oriveo.community.core.context.MemoryIntentLexicon
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItemScope
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryScopeType
import ai.oriveo.community.core.context.MemorySensitivity
import ai.oriveo.community.core.context.MemorySourceType
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.dao.MemoryCandidateDao
import ai.oriveo.community.core.data.dao.MemoryItemDao
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.MemoryCandidateEntity
import ai.oriveo.community.core.data.entity.MemoryItemEntity
import io.mockk.every
import io.mockk.mockk
import java.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * MemoryCandidateRepository (generate / accept / reject / pending) and item createFromDraft.
 * Case names are shared with the other platforms.
 */
@RunWith(RobolectricTestRunner::class)
class MemoryCandidateRepositoryTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase
    private lateinit var items: MemoryItemRepository
    private lateinit var candidates: MemoryCandidateRepository
    private lateinit var preferences: AppPreferencesRepository
    private var idCounter = 0
    private val localWrites = mutableListOf<String>()

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        preferences = AppPreferencesRepository(preferenceDao = db.preferenceDao())
        items = MemoryItemRepository(
            dao = db.memoryItemDao(),
            preferenceDao = db.preferenceDao(),
            preferences = preferences,
            now = { Instant.ofEpochMilli(T0 + 60_000) },
            newId = { "0000000%d-AAAA-4BBB-8CCC-DDDDDDDDDDDD".format(++idCounter) },
            runInTransaction = { block -> db.withTransaction { block() } },
        )
        items.onLocalWrite = { localWrites += it }
        candidates = MemoryCandidateRepository(
            dao = db.memoryCandidateDao(),
            items = items,
            now = { T0 },
            io = Dispatchers.Unconfined,
            preferences = preferences,
        )
    }

    @After
    fun tearDown() {
        db.close()
    }

    private suspend fun generate(
        text: String,
        messageId: String = "m1",
        nowMs: Long = T0,
        accountId: String = ACCOUNT_A,
        folderId: String? = null,
        useMemory: Boolean = true,
    ): MemoryCandidate? = candidates.generate(accountId, text, messageId, CONVERSATION, folderId, useMemory, nowMs)

    private fun MemoryCandidateResult<MemoryItem>.item(): MemoryItem =
        (this as? MemoryCandidateResult.Ok)?.value ?: error("expected Ok, got $this")

    @Test
    fun generate_creates_pending_for_explicit_remember() = runBlocking {
        val candidate = generate(EXPLICIT_TEXT)
        assertNotNull(candidate)
        candidate!!
        assertEquals(MemoryCandidateStatus.PENDING, candidate.status)
        assertEquals(EXPLICIT_PROPOSITION, candidate.content)
        assertEquals(MemoryKind.PREFERENCE, candidate.proposedKind)
        assertEquals(MemoryLayer.SEMANTIC, candidate.proposedLayer)
        assertEquals(MemoryItemScope(MemoryScopeType.GLOBAL, null), candidate.scope)
        assertEquals(MemorySourceType.CONVERSATION, candidate.source.type)
        assertEquals(CONVERSATION, candidate.source.conversationId)
        assertEquals(listOf("m1"), candidate.source.messageIds)
        assertEquals(T0, candidate.source.observedAtMs)
        assertEquals(MemoryIntentLexicon.CONFIDENCE_EXPLICIT, candidate.confidence, 0.0)
        assertEquals(MemoryIntent.fingerprint(EXPLICIT_PROPOSITION), candidate.fingerprint)
        assertEquals(T0, candidate.createdAtMs)
        assertEquals(T0 + MemoryIntentLexicon.CANDIDATE_TTL_MS, candidate.expiresAtMs)
        assertNull(candidate.resolvedAtMs)

        // Stored and read back identical as a whole (the JSON round trip is lossless), and the row state column is in sync.
        assertEquals(listOf(candidate), candidates.pending(ACCOUNT_A, T0))
        assertEquals(candidate, candidates.get(ACCOUNT_A, candidate.id))
        assertEquals("pending", db.memoryCandidateDao().get(ACCOUNT_A, candidate.id)?.status)
    }

    @Test
    fun generate_skips_no_suggestion() = runBlocking {
        assertNull(generate("The rememberMe flag is broken"))
        assertNull(generate("Stop adding disclaimers to your replies.", messageId = "m2"))
        assertTrue(candidates.pending(ACCOUNT_A, T0).isEmpty())
        assertTrue(db.memoryCandidateDao().list(ACCOUNT_A).isEmpty())
    }

    @Test
    fun generate_no_suggestion_touches_no_storage() = runBlocking {
        // An unreadable row: any generate that runs the sweep deletes it, so it surviving means the database was not touched.
        val unreadable = MemoryCandidateEntity(accountId = ACCOUNT_A, id = "broken", status = "pending", payload = "{")
        db.memoryCandidateDao().upsert(unreadable)
        assertNull(generate("The rememberMe flag is broken"))
        assertNull(generate("Stop adding disclaimers to your replies.", messageId = "m2"))
        assertNull(generate(EXPLICIT_TEXT, messageId = "m3", useMemory = false))
        assertEquals(listOf(unreadable), db.memoryCandidateDao().list(ACCOUNT_A))
    }

    @Test
    fun generate_skips_when_use_memory_off() = runBlocking {
        assertNull(generate(EXPLICIT_TEXT, useMemory = false))
        assertTrue(db.memoryCandidateDao().list(ACCOUNT_A).isEmpty())
        // Judging the same message again with memory on generates as usual (nothing was recorded while it was off).
        assertNotNull(generate(EXPLICIT_TEXT, useMemory = true))
    }

    @Test
    fun generate_skips_duplicate_active() = runBlocking {
        val paused = items.create(ACCOUNT_A, MemoryKind.PREFERENCE, EXPLICIT_PROPOSITION)
        items.setPaused(ACCOUNT_A, paused.id, true)
        assertNull("the text of a paused item also counts as existing", generate(EXPLICIT_TEXT))
        assertTrue(db.memoryCandidateDao().list(ACCOUNT_A).isEmpty())

        // A tombstone left by a delete does not count: saying the same sentence again generates a candidate.
        items.delete(ACCOUNT_A, paused.id)
        assertNotNull(generate(EXPLICIT_TEXT, messageId = "m2"))
    }

    @Test
    fun generate_same_message_idempotent() = runBlocking {
        val first = generate(EXPLICIT_TEXT)
        assertNotNull(first)
        assertNull(generate(EXPLICIT_TEXT, nowMs = T0 + 1_000))
        // Another message says the same sentence: a pending with the same fingerprint exists, so nothing is generated.
        assertNull(generate(EXPLICIT_TEXT, messageId = "m2", nowMs = T0 + 2_000))
        assertEquals(listOf(first), candidates.pending(ACCOUNT_A, T0 + 2_000))
        assertEquals(1, db.memoryCandidateDao().list(ACCOUNT_A).size)
    }

    @Test
    fun generate_in_folder_scopes_folder() = runBlocking {
        val unspecified = generate(EXPLICIT_TEXT, folderId = FOLDER)
        assertEquals(MemoryItemScope(MemoryScopeType.FOLDER, FOLDER), unspecified?.scope)
        val folderScoped = generate(FOLDER_TEXT, messageId = "m2", folderId = FOLDER)
        assertEquals(MemoryItemScope(MemoryScopeType.FOLDER, FOLDER), folderScoped?.scope)
        // Not in a folder: the folder intent falls back to this conversation.
        val outside = generate(FOLDER_TEXT, messageId = "m3", accountId = ACCOUNT_B)
        assertEquals(MemoryItemScope(MemoryScopeType.CONVERSATION, CONVERSATION), outside?.scope)
    }

    @Test
    fun reject_keeps_fingerprint_only_and_blocks_regeneration() = runBlocking {
        val candidate = generate(EXPLICIT_TEXT)!!
        val rejectAt = T0 + 5_000
        val result = candidates.reject(ACCOUNT_A, candidate.id, rejectAt)
        val rejected = (result as MemoryCandidateResult.Ok).value
        assertEquals(MemoryCandidateStatus.REJECTED, rejected.status)
        assertEquals("", rejected.content)
        assertNull(rejected.source.conversationId)
        assertTrue(rejected.source.messageIds.isEmpty())
        assertNull(rejected.source.observedAtMs)
        assertEquals(candidate.fingerprint, rejected.fingerprint)
        assertEquals(rejectAt, rejected.resolvedAtMs)
        assertEquals(rejectAt + MemoryIntentLexicon.CANDIDATE_TTL_MS, rejected.expiresAtMs)

        val row = db.memoryCandidateDao().get(ACCOUNT_A, candidate.id)
        assertEquals("rejected", row?.status)
        assertTrue("the database keeps no text", row?.payload?.contains(EXPLICIT_PROPOSITION) == false)
        assertEquals(rejected, candidates.get(ACCOUNT_A, candidate.id))
        assertTrue(candidates.pending(ACCOUNT_A, rejectAt).isEmpty())

        // Within the reject window another message with the same sentence is not proposed again; rejecting twice / rejecting a missing one -> not_pending.
        assertNull(generate(EXPLICIT_TEXT, messageId = "m2", nowMs = rejectAt + 1_000))
        assertEquals(MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING), candidates.reject(ACCOUNT_A, candidate.id, rejectAt))
        assertEquals(MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING), candidates.reject(ACCOUNT_A, "missing", rejectAt))

        // Once the rejection expires the row is cleared and the same sentence can be proposed again.
        val later = rejectAt + MemoryIntentLexicon.CANDIDATE_TTL_MS
        val again = generate(EXPLICIT_TEXT, messageId = "m3", nowMs = later)
        assertNotNull(again)
        assertNull(db.memoryCandidateDao().get(ACCOUNT_A, candidate.id))
    }

    @Test
    fun accept_creates_item_and_removes_candidate() = runBlocking {
        val candidate = generate(EXPLICIT_TEXT, nowMs = OBSERVED_MS)!!
        localWrites.clear()
        val accepted = candidates.accept(ACCOUNT_A, candidate.id, null, OBSERVED_MS + 1_000).item()

        val stored = items.get(ACCOUNT_A, accepted.id)
        assertNotNull(stored)
        stored!!
        assertEquals(accepted, stored)
        assertTrue("a new id; the candidate id is not reused", stored.id != candidate.id)
        assertEquals(MemoryStatus.ACTIVE, stored.status)
        assertEquals(MemoryLayer.SEMANTIC, stored.layer)
        assertEquals(MemoryKind.PREFERENCE, stored.kind)
        assertEquals(EXPLICIT_PROPOSITION, stored.content)
        assertEquals(MemoryItemScope(MemoryScopeType.GLOBAL, null), stored.scope)
        assertEquals(MemorySourceType.CONVERSATION, stored.source.type)
        assertEquals(CONVERSATION, stored.source.conversationId)
        assertEquals(listOf("m1"), stored.source.messageIds)
        assertEquals("2026-10-16T08:00:00Z", stored.source.observedAt)
        assertEquals(MemorySensitivity.NORMAL, stored.sensitivity)
        assertEquals(MemoryIntentLexicon.CONFIDENCE_EXPLICIT, stored.confidence, 0.0)
        assertEquals(listOf(stored.id), items.pending(ACCOUNT_A).map { it.id })
        assertEquals(listOf(ACCOUNT_A), localWrites)
        assertEquals(
            "dual-writes memoryText",
            true,
            db.preferenceDao().get(AppPreferenceKeys.MEMORY_TEXT)?.contains(EXPLICIT_PROPOSITION),
        )

        assertNull(db.memoryCandidateDao().get(ACCOUNT_A, candidate.id))
        assertTrue(candidates.pending(ACCOUNT_A, OBSERVED_MS + 1_000).isEmpty())
        assertEquals(
            MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING),
            candidates.accept(ACCOUNT_A, candidate.id, null, OBSERVED_MS + 2_000),
        )
    }

    @Test
    fun accept_rolls_back_when_candidate_delete_fails() = runBlocking {
        val candidate = generate(EXPLICIT_TEXT)!!
        // The first delete of the candidate fails: creating the item and deleting the candidate share one transaction, so everything rolls back.
        val realDao = db.memoryCandidateDao()
        var failDelete = true
        val failingDao = object : MemoryCandidateDao by realDao {
            override suspend fun delete(accountId: String, id: String) {
                if (failDelete) {
                    failDelete = false
                    throw IllegalStateException("candidate delete failed")
                }
                realDao.delete(accountId, id)
            }
        }
        val failing = MemoryCandidateRepository(
            dao = failingDao,
            items = items,
            now = { T0 },
            io = Dispatchers.Unconfined,
            preferences = preferences,
        )

        val thrown = runCatching { failing.accept(ACCOUNT_A, candidate.id, null, T0 + 1_000) }.exceptionOrNull()
        assertTrue("delete failure surfaces: $thrown", thrown is IllegalStateException)
        assertTrue("no item left behind", items.list(ACCOUNT_A).isEmpty())
        assertTrue(db.memoryItemDao().list(ACCOUNT_A).isEmpty())
        assertNull(db.preferenceDao().get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals(MemoryCandidateStatus.PENDING.wire, db.memoryCandidateDao().get(ACCOUNT_A, candidate.id)?.status)

        // Accepting again yields only one item.
        val accepted = failing.accept(ACCOUNT_A, candidate.id, null, T0 + 2_000).item()
        assertEquals(listOf(accepted.id), items.list(ACCOUNT_A).map { it.id })
        assertNull(db.memoryCandidateDao().get(ACCOUNT_A, candidate.id))
    }

    @Test
    fun accept_and_remote_apply_do_not_deadlock() = runBlocking {
        val seed = candidates.accept(ACCOUNT_A, generate(EXPLICIT_TEXT)!!.id, null, T0 + 1_000).item()
        val pending = generate(IMPLICIT_TEXT, messageId = "m2", nowMs = T0 + 1_500)!!
        // A remote apply holds the item write lock and then pauses, so that accept starts in the meantime:
        // the old implementation opened the transaction first and then waited for the write lock while the apply held the lock and waited for the transaction -> deadlock; now accept waits for the write lock before opening the transaction.
        val realDao = db.memoryItemDao()
        val remoteHoldsLock = CompletableDeferred<Unit>()
        val slowDao = object : MemoryItemDao by realDao {
            override suspend fun get(accountId: String, id: String): MemoryItemEntity? {
                if (id == REMOTE_ID && remoteHoldsLock.complete(Unit)) delay(300)
                return realDao.get(accountId, id)
            }
        }
        val slowItems = MemoryItemRepository(
            dao = slowDao,
            preferenceDao = db.preferenceDao(),
            preferences = preferences,
            now = { Instant.ofEpochMilli(T0 + 60_000) },
            newId = { "1000000%d-AAAA-4BBB-8CCC-DDDDDDDDDDDD".format(++idCounter) },
            runInTransaction = { block -> db.withTransaction { block() } },
        )
        val slowCandidates = MemoryCandidateRepository(
            dao = db.memoryCandidateDao(),
            items = slowItems,
            now = { T0 },
            io = Dispatchers.Unconfined,
            preferences = preferences,
        )
        val remote = seed.copy(id = REMOTE_ID, content = "item written remotely", mutationId = "c9000001-aaaa-4bbb-8ccc-dddddddddddd")

        val accepted = withTimeout(10_000) {
            coroutineScope {
                val applying = launch { slowItems.syncApplyRemote(ACCOUNT_A, remote) }
                remoteHoldsLock.await()
                val accepting = async { slowCandidates.accept(ACCOUNT_A, pending.id, null, T0 + 2_000) }
                applying.join()
                accepting.await().item()
            }
        }

        assertEquals("item written remotely", realDao.get(ACCOUNT_A, REMOTE_ID)?.toItem()?.content)
        assertNotNull(realDao.get(ACCOUNT_A, accepted.id))
        assertNull(db.memoryCandidateDao().get(ACCOUNT_A, pending.id))
        assertEquals(setOf(seed.id, REMOTE_ID, accepted.id), items.list(ACCOUNT_A).map { it.id }.toSet())
    }

    @Test
    fun accept_edited_content_confidence_one() = runBlocking {
        val plain = generate(IMPLICIT_TEXT)!!
        assertEquals(MemoryIntentLexicon.CONFIDENCE_IMPLICIT, plain.confidence, 0.0)
        val kept = candidates.accept(ACCOUNT_A, plain.id, null, T0 + 1_000).item()
        assertEquals(MemoryIntentLexicon.CONFIDENCE_IMPLICIT, items.get(ACCOUNT_A, kept.id)!!.confidence, 0.0)

        val edited = generate(EXPLICIT_TEXT, messageId = "m2")!!
        val result = candidates.accept(
            ACCOUNT_A,
            edited.id,
            MemoryCandidateEdit(content = "  \u6211\u504f\u597d\u975e\u5e38\u7b80\u6d01\u7684\u56de\u7b54 ", kind = MemoryKind.INSTRUCTION),
            T0 + 2_000,
        ).item()
        val stored = items.get(ACCOUNT_A, result.id)!!
        assertEquals("\u6211\u504f\u597d\u975e\u5e38\u7b80\u6d01\u7684\u56de\u7b54", stored.content)
        assertEquals(MemoryKind.INSTRUCTION, stored.kind)
        assertEquals(1.0, stored.confidence, 0.0)

        // Edited to empty -> empty, and the candidate stays.
        val third = generate(FOLDER_TEXT, messageId = "m3")!!
        assertEquals(
            MemoryCandidateResult.Failed(MemoryCandidateError.EMPTY),
            candidates.accept(ACCOUNT_A, third.id, MemoryCandidateEdit(content = "   "), T0 + 3_000),
        )
        assertNotNull(db.memoryCandidateDao().get(ACCOUNT_A, third.id))
    }

    @Test
    fun accept_expired_errors_and_purges() = runBlocking {
        val candidate = generate(EXPLICIT_TEXT)!!
        val result = candidates.accept(ACCOUNT_A, candidate.id, null, candidate.expiresAtMs)
        assertEquals(MemoryCandidateResult.Failed(MemoryCandidateError.EXPIRED), result)
        assertNull(db.memoryCandidateDao().get(ACCOUNT_A, candidate.id))
        assertTrue(items.list(ACCOUNT_A).isEmpty())
        assertEquals(
            MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING),
            candidates.accept(ACCOUNT_A, "missing", null, T0),
        )
    }

    @Test
    fun pending_sweeps_expired_and_superseded() = runBlocking {
        val expired = generate(EXPLICIT_TEXT, messageId = "m1", nowMs = T0)!!
        val b = generate("\u5e2e\u6211\u8bb0\u4e00\u4e0b，\u6211\u4f4f\u5728\u676d\u5dde", messageId = "m2", nowMs = T0 + 1_000)!!
        val d = generate("\u8bb0\u4e0b\u6765：\u6211\u5bf9\u82b1\u751f\u8fc7\u654f", messageId = "m3", nowMs = T0 + 1_000)!!
        val e = generate("\u522b\u5fd8\u4e86\u6211\u4e0d\u5403\u8fa3", messageId = "m4", nowMs = T0 + 1_500)!!
        val superseded = generate("\u597d\u7684，\u8bb0\u4f4f\u6211\u53eb\u5c0f\u6797", messageId = "m5", nowMs = T0 + 2_000)!!
        items.create(ACCOUNT_A, superseded.proposedKind, superseded.content)

        val at = T0 + MemoryIntentLexicon.CANDIDATE_TTL_MS + 500
        val listed = candidates.pending(ACCOUNT_A, at)
        assertEquals(listOf(e.id) + listOf(b.id, d.id).sorted(), listed.map { it.id })
        assertNull(db.memoryCandidateDao().get(ACCOUNT_A, expired.id))
        assertNull(db.memoryCandidateDao().get(ACCOUNT_A, superseded.id))
        assertEquals(3, db.memoryCandidateDao().list(ACCOUNT_A).size)
    }

    @Test
    fun candidates_partitioned_by_account() = runBlocking {
        val a = generate(EXPLICIT_TEXT, accountId = ACCOUNT_A)!!
        assertTrue(candidates.pending(ACCOUNT_B, T0).isEmpty())
        assertNull(candidates.get(ACCOUNT_B, a.id))
        assertEquals(
            MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING),
            candidates.accept(ACCOUNT_B, a.id, null, T0 + 1_000),
        )
        assertEquals(
            MemoryCandidateResult.Failed(MemoryCandidateError.NOT_PENDING),
            candidates.reject(ACCOUNT_B, a.id, T0 + 1_000),
        )

        // The same sentence of the same message is generated independently for B (same id, different partition); A's items do not count as B's existing ones.
        items.create(ACCOUNT_A, MemoryKind.FACT, "\u6211\u4f4f\u5728\u676d\u5dde")
        val b = generate(EXPLICIT_TEXT, accountId = ACCOUNT_B)!!
        assertEquals(a.id, b.id)
        assertNotNull(generate("\u5e2e\u6211\u8bb0\u4e00\u4e0b，\u6211\u4f4f\u5728\u676d\u5dde", messageId = "m2", accountId = ACCOUNT_B))
        assertEquals(listOf(a), candidates.pending(ACCOUNT_A, T0))
        assertEquals(2, candidates.pending(ACCOUNT_B, T0).size)
    }

    @Test
    fun no_candidate_becomes_active_without_accept() = runBlocking {
        val first = generate(EXPLICIT_TEXT)!!
        generate(IMPLICIT_TEXT, messageId = "m2")!!
        generate(FOLDER_TEXT, messageId = "m3", folderId = FOLDER)!!
        candidates.reject(ACCOUNT_A, first.id, T0 + 1_000)
        candidates.pending(ACCOUNT_A, T0 + MemoryIntentLexicon.CANDIDATE_TTL_MS + 1)

        assertTrue(items.list(ACCOUNT_A).isEmpty())
        assertTrue(db.memoryItemDao().list(ACCOUNT_A).isEmpty())
        assertNull(db.preferenceDao().get(AppPreferenceKeys.MEMORY_TEXT))
        assertTrue(localWrites.isEmpty())
    }

    @Test
    fun auto_suggest_pref_defaults_on_and_persists_on_this_device() = runBlocking {
        assertTrue(candidates.autoSuggestEnabled(ACCOUNT_A))

        candidates.setAutoSuggestEnabled(ACCOUNT_A, false)

        assertEquals(false, candidates.autoSuggestEnabled(ACCOUNT_A))
        assertEquals(
            "false",
            db.preferenceDao().get(AppPreferenceKeys.MEMORY_AUTO_SUGGEST_ENABLED),
        )

        candidates.setAutoSuggestEnabled(ACCOUNT_A, true)
        assertTrue(candidates.autoSuggestEnabled(ACCOUNT_A))
    }

    @Test
    fun generate_skips_implicit_when_auto_suggest_off() = runBlocking {
        val earlier = generate(FOLDER_TEXT, messageId = "m0", folderId = FOLDER)!!
        candidates.setAutoSuggestEnabled(ACCOUNT_A, false)

        assertNull(generate(IMPLICIT_TEXT))
        // An explicit "remember" still creates a pending; turning the switch off does not delete an existing pending.
        val explicit = generate(EXPLICIT_TEXT, messageId = "m2")!!
        assertEquals(MemoryCandidateStatus.PENDING, explicit.status)
        val rows = db.memoryCandidateDao().list(ACCOUNT_A)
        assertEquals(setOf(earlier.id, explicit.id), rows.map { it.id }.toSet())
        assertTrue(rows.all { it.status == MemoryCandidateStatus.PENDING.wire })
    }

    // ---- propose group (only create writes a candidate, reusing the generate storage) ----

    private suspend fun propose(
        arguments: String,
        userText: String = EXPLICIT_TEXT,
        priorInTurn: Int = 0,
        messageId: String = "m1",
        folderId: String? = null,
        accountId: String = ACCOUNT_A,
        nowMs: Long = T0,
    ): MemoryCandidate? = candidates.propose(accountId, arguments, priorInTurn, userText, messageId, CONVERSATION, folderId, nowMs)

    @Test
    fun propose_creates_pending_and_persists() = runBlocking {
        val candidate = propose(PROPOSE_ARGS)
        assertNotNull(candidate)
        candidate!!
        assertEquals(MemoryCandidateStatus.PENDING, candidate.status)
        assertEquals(EXPLICIT_PROPOSITION, candidate.content)
        assertEquals(MemoryKind.PREFERENCE, candidate.proposedKind)
        assertEquals(MemoryItemScope(MemoryScopeType.GLOBAL, null), candidate.scope)
        assertEquals(listOf("m1"), candidate.source.messageIds)
        assertEquals(MemoryIntentLexicon.CONFIDENCE_IMPLICIT, candidate.confidence, 0.0)
        assertEquals(MemoryIntent.fingerprint(EXPLICIT_PROPOSITION), candidate.fingerprint)
        // Same message id rule as the fixture create_zh_explicit_global: id = UUIDv5(messageId \n fingerprint).
        assertEquals(listOf(candidate), candidates.pending(ACCOUNT_A, T0))
        assertEquals("pending", db.memoryCandidateDao().get(ACCOUNT_A, candidate.id)?.status)
    }

    @Test
    fun propose_skip_returns_null_and_writes_nothing() = runBlocking {
        assertNull(propose("{\"proposition\": \"\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54\""))
        assertNull(propose("[\"\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54\"]"))
        assertNull(propose(PROPOSE_ARGS, userText = "\u4eca\u5929\u5929\u6c14\u4e0d\u9519"))
        assertNull(propose(PROPOSE_ARGS, priorInTurn = 3))
        assertNull(propose(PROPOSE_ARGS, userText = "\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54，\u6211\u7684\u5bc6\u7801\u662f hunter2"))
        assertTrue(db.memoryCandidateDao().list(ACCOUNT_A).isEmpty())
        // Within the limit it is created as usual.
        assertNotNull(propose(PROPOSE_ARGS, priorInTurn = 2))
    }

    @Test
    fun propose_collides_with_generate_on_same_message() = runBlocking {
        val generated = generate(EXPLICIT_TEXT)!!
        assertNull(propose(PROPOSE_ARGS))
        assertNull("a pending with the same fingerprint already exists", propose(PROPOSE_ARGS, messageId = "m2"))
        assertEquals(listOf(generated), candidates.pending(ACCOUNT_A, T0))
    }

    @Test
    fun propose_skips_duplicate_active() = runBlocking {
        items.create(ACCOUNT_A, MemoryKind.PREFERENCE, EXPLICIT_PROPOSITION)
        assertNull(propose(PROPOSE_ARGS))
        assertTrue(db.memoryCandidateDao().list(ACCOUNT_A).isEmpty())
    }

    @Test
    fun propose_ignores_auto_suggest_switch_and_scopes_folder() = runBlocking {
        // The auto-candidate switch is decided by the mode (off -> fallback); propose itself does not look at it.
        candidates.setAutoSuggestEnabled(ACCOUNT_A, false)
        val candidate = propose(PROPOSE_ARGS, folderId = FOLDER)
        assertEquals(MemoryItemScope(MemoryScopeType.FOLDER, FOLDER), candidate?.scope)
        assertNull(candidates.get(ACCOUNT_B, candidate!!.id))
    }

    private companion object {
        const val ACCOUNT_A = "user-a"
        const val ACCOUNT_B = "user-b"
        const val CONVERSATION = "conv-1"
        const val FOLDER = "folder-1"
        const val T0 = 1_792_137_600_000L
        const val OBSERVED_MS = 1_792_137_600_123L

        // Sentences from the cases in shared/context-contracts/memory-intent.v1.json.
        const val EXPLICIT_TEXT = "\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54"
        const val REMOTE_ID = "c9000002-aaaa-4bbb-8ccc-dddddddddddd"
        const val EXPLICIT_PROPOSITION = "\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54"
        const val IMPLICIT_TEXT = "\u4ee5\u540e\u6240\u6709\u5bf9\u8bdd\u90fd\u7528\u7b80\u4f53\u4e2d\u6587\u56de\u590d\u6211"
        const val FOLDER_TEXT = "\u8fd9\u4e2a\u9879\u76ee\u91cc\u4ee5\u540e\u90fd\u7528 TypeScript \u5199"

        // Arguments of proposeCases create_zh_explicit_global in shared/context-contracts/memory-propose.v2.json.
        const val PROPOSE_ARGS =
            "{\"proposition\":\"\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54\",\"kind\":\"preference\",\"scope\":\"unspecified\",\"sourceQuote\":\"\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54\"}"
    }
}
