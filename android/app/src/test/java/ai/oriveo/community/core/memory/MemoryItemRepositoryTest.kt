package ai.oriveo.community.core.memory

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.MemoryCandidateSource
import ai.oriveo.community.core.context.MemoryConflictResolution
import ai.oriveo.community.core.context.MemoryItemDraft
import ai.oriveo.community.core.context.MemoryItemScope
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemorySensitivity
import ai.oriveo.community.core.context.MemoryServerTime
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.MemoryItemEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.mcp.mcpSha256Hex
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.spyk
import io.mockk.verify
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The memory_items table and MemoryItemRepository create / edit / delete, pin and pause, and clearing the partition.
 * Also legacySync migration / edit flow-back from older clients, and the dual write of memoryText + digest after an item write.
 */
@RunWith(RobolectricTestRunner::class)
class MemoryItemRepositoryTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase
    private lateinit var repository: MemoryItemRepository
    private lateinit var preferences: AppPreferencesRepository
    private var clock: Instant = Instant.parse("2026-10-16T08:00:00Z")
    private var idCounter = 0

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        preferences = preferencesFor(db)
        // The upper-case id proves the id is canonicalized (lower-cased) before it is written.
        repository = MemoryItemRepository(
            dao = db.memoryItemDao(),
            preferenceDao = db.preferenceDao(),
            preferences = preferences,
            now = { clock },
            newId = { "0000000%d-AAAA-4BBB-8CCC-DDDDDDDDDDDD".format(++idCounter) },
        )
    }

    private fun preferencesFor(database: OriveoDatabase): AppPreferencesRepository {
        return AppPreferencesRepository(preferenceDao = database.preferenceDao())
    }

    private suspend fun pref(key: String, accountId: String, database: OriveoDatabase = db): String? =
        database.preferenceDao().get(key)

    private suspend fun setPref(key: String, accountId: String, value: String, database: OriveoDatabase = db) {
        database.preferenceDao().set(PreferenceEntity(key, value))
    }

    /** Preferences written by an older client: memoryText + Anti-Forget, no digest. */
    private suspend fun seedOldClientPrefs(database: OriveoDatabase = db) {
        setPref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID, "I write novels.", database)
        setPref(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, FIXTURE_UID, "true", database)
        setPref(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, FIXTURE_UID, "Always answer in Arabic.", database)
        setPref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID, "2026-10-01T00:00:00Z", database)
    }

    @After
    fun tearDown() {
        db.close()
    }

    private fun tick(seconds: Long = 1) {
        clock = clock.plusSeconds(seconds)
    }

    @Test
    fun create_lists_in_order() = runBlocking {
        val first = repository.create(ACCOUNT_A, MemoryKind.FACT, "Lives in Hangzhou")
        tick()
        val second = repository.create(ACCOUNT_A, MemoryKind.PREFERENCE, "Likes short answers")
        tick()
        val third = repository.create(ACCOUNT_A, MemoryKind.INSTRUCTION, "Answer in Chinese")

        val listed = repository.list(ACCOUNT_A)
        assertEquals(listOf(first.id, second.id, third.id), listed.map { it.id })
        assertEquals(listed, repository.observe(ACCOUNT_A).first())
        assertEquals(MemoryItems.listOrder(listed), listed)

        val deviceId = db.preferenceDao().get(AppPreferenceKeys.MEMORY_DEVICE_ID)
        assertNotNull("the first write generates this device id", deviceId)
        listed.forEach { item ->
            assertEquals(item.id.lowercase(), item.id)
            assertEquals(item.mutationId.lowercase(), item.mutationId)
            assertNotEquals(item.id, item.mutationId)
            assertEquals(deviceId, item.deviceId)
            assertEquals(1, item.revision)
            assertEquals(0, item.baseRevision)
            assertEquals(MemoryStatus.ACTIVE, item.status)
        }
        assertEquals(MemoryServerTime.At("2026-10-16T08:00:00Z"), first.createdAt)
        assertEquals(MemoryServerTime.At("2026-10-16T08:00:02Z"), third.createdAt)
        assertEquals(listed, repository.pending(ACCOUNT_A))
        assertTrue(repository.list(ACCOUNT_B).isEmpty())
    }

    @Test
    fun l3_create_sets_occurred_at_now() = runBlocking {
        // A new L3 item without occurredAt gets now; a given one is used as is; L2 is not filled.
        val manual = repository.create(FIXTURE_UID, MemoryKind.EVENT, "Moved the standup to 10am", layer = MemoryLayer.EPISODIC)
        assertEquals(clock.toString(), manual.occurredAt)
        val given = repository.create(
            FIXTURE_UID, MemoryKind.EVENT, "Shipped v2.3 on October 3", layer = MemoryLayer.EPISODIC,
            occurredAt = "2026-10-03T00:00:00Z",
        )
        assertEquals("2026-10-03T00:00:00Z", given.occurredAt)
        val semantic = repository.create(FIXTURE_UID, MemoryKind.FACT, "Likes tea")
        assertNull(semantic.occurredAt)
        val accepted = repository.createFromDraft(
            FIXTURE_UID,
            MemoryItemDraft(
                layer = MemoryLayer.EPISODIC,
                kind = MemoryKind.DECISION,
                status = MemoryStatus.ACTIVE,
                content = "Decided the cover is dark blue",
                scope = MemoryItemScope(),
                source = MemoryCandidateSource(conversationId = "conv-1", messageIds = listOf("m-1"), observedAtMs = 1_792_137_600_000L),
                sensitivity = MemorySensitivity.NORMAL,
                confidence = 0.8,
            ),
        )
        assertEquals(clock.toString(), accepted.occurredAt)
        assertEquals(clock.toString(), repository.get(FIXTURE_UID, accepted.id)!!.occurredAt)
    }

    @Test
    fun l3_conflict_marks_both_and_resolve_writes_patches() = runBlocking {
        val older = repository.create(FIXTURE_UID, MemoryKind.DECISION, "Decided the saga ends in 1453 in Constantinople", layer = MemoryLayer.EPISODIC)
        assertEquals(MemoryStatus.ACTIVE, older.status)
        val newer = repository.create(FIXTURE_UID, MemoryKind.DECISION, "Decided the saga ends in 1460 in Constantinople", layer = MemoryLayer.EPISODIC)
        // A conflict is detected after saving: both the new and the old item become conflicted, and the group id is the old item id.
        assertEquals(MemoryStatus.CONFLICTED, newer.status)
        assertEquals(older.id, newer.conflictGroupId)
        val olderRow = repository.get(FIXTURE_UID, older.id)!!
        assertEquals(MemoryStatus.CONFLICTED, olderRow.status)
        assertEquals(older.id, olderRow.conflictGroupId)
        assertNotEquals(older.mutationId, olderRow.mutationId)
        // Different kinds do not conflict.
        val event = repository.create(FIXTURE_UID, MemoryKind.EVENT, "Decided the saga ends in 1470 in Constantinople", layer = MemoryLayer.EPISODIC)
        assertEquals(MemoryStatus.ACTIVE, event.status)

        val written = repository.resolveL3Conflict(FIXTURE_UID, newer.id, older.id, MemoryConflictResolution.USE_NEW)!!
        assertEquals(listOf(newer.id, older.id), written.map { it.id })
        val newerRow = repository.get(FIXTURE_UID, newer.id)!!
        assertEquals(MemoryStatus.ACTIVE, newerRow.status)
        assertNull(newerRow.conflictGroupId)
        assertEquals(listOf(older.id), newerRow.supersedes)
        val supersededRow = repository.get(FIXTURE_UID, older.id)!!
        assertEquals(MemoryStatus.SUPERSEDED, supersededRow.status)
        assertNull(supersededRow.conflictGroupId)
        // Nothing is deleted.
        assertEquals(3, repository.list(FIXTURE_UID).count { it.layer == MemoryLayer.EPISODIC && it.status != MemoryStatus.DELETED })
    }

    @Test
    fun edit_marks_pending() = runBlocking {
        val created = repository.create(ACCOUNT_A, MemoryKind.FACT, "Lives in Hangzhou")
        // Simulates a confirmed push: revision 3, syncState synced.
        db.memoryItemDao().upsert(created.copy(revision = 3).toEntity(ACCOUNT_A, MemoryItemEntity.SYNC_SYNCED))
        assertTrue(repository.pending(ACCOUNT_A).isEmpty())

        tick()
        val edited = repository.edit(ACCOUNT_A, created.id.uppercase(), "Lives in Shanghai", MemoryKind.PROJECT)

        assertNotNull(edited)
        val pending = repository.pending(ACCOUNT_A)
        assertEquals(listOf(edited), pending)
        val stored = pending.single()
        assertEquals("Lives in Shanghai", stored.content)
        assertEquals(MemoryKind.PROJECT, stored.kind)
        assertEquals(3, stored.revision)
        assertEquals(3, stored.baseRevision)
        assertNotEquals(created.mutationId, stored.mutationId)
        assertEquals(created.deviceId, stored.deviceId)
        assertEquals("editing does not change createdAt", created.createdAt, stored.createdAt)
        assertNull("a missing item is not written", repository.edit(ACCOUNT_A, "missing", "x"))
        assertNull("another account cannot see it", repository.edit(ACCOUNT_B, created.id, "x"))
    }

    @Test
    fun delete_writes_tombstone() = runBlocking {
        val created = repository.create(ACCOUNT_A, MemoryKind.FACT, "Lives in Hangzhou")
        db.memoryItemDao().upsert(created.copy(revision = 2).toEntity(ACCOUNT_A, MemoryItemEntity.SYNC_SYNCED))
        tick(60)

        val tombstone = repository.delete(ACCOUNT_A, created.id)

        assertNotNull(tombstone)
        val stored = repository.get(ACCOUNT_A, created.id)
        assertEquals(tombstone, stored)
        assertEquals(
            MemoryItems.tombstone(created.copy(revision = 2), stored!!.mutationId, created.deviceId, "2026-10-16T08:01:00Z"),
            stored,
        )
        assertEquals(MemoryStatus.DELETED, stored.status)
        assertEquals("", stored.content)
        assertEquals(2, stored.baseRevision)
        assertNotEquals(created.mutationId, stored.mutationId)
        assertEquals("a tombstone does not hard-delete the row", listOf(stored), repository.list(ACCOUNT_A))
        assertEquals(listOf(stored), repository.pending(ACCOUNT_A))
        assertNull("a deleted item cannot be edited", repository.edit(ACCOUNT_A, created.id, "revive"))
        assertNull("a deleted item is not deleted twice", repository.delete(ACCOUNT_A, created.id))
    }

    @Test
    fun pin_and_pause() = runBlocking {
        val older = repository.create(ACCOUNT_A, MemoryKind.FACT, "Lives in Hangzhou")
        tick()
        val newer = repository.create(ACCOUNT_A, MemoryKind.PREFERENCE, "Likes short answers")

        val pinned = repository.setPinned(ACCOUNT_A, newer.id, true)
        assertEquals(true, pinned?.pinned)
        assertNotEquals(newer.mutationId, pinned?.mutationId)
        assertEquals("pinned sorts first", listOf(newer.id, older.id), repository.list(ACCOUNT_A).map { it.id })

        val paused = repository.setPaused(ACCOUNT_A, older.id, true)
        assertEquals(MemoryStatus.PAUSED, repository.get(ACCOUNT_A, older.id)?.status)
        assertNotEquals(older.mutationId, paused?.mutationId)

        val resumed = repository.setPaused(ACCOUNT_A, older.id, false)
        assertEquals(MemoryStatus.ACTIVE, repository.get(ACCOUNT_A, older.id)?.status)
        assertNotEquals(paused?.mutationId, resumed?.mutationId)

        repository.setPinned(ACCOUNT_A, newer.id, false)
        assertEquals(listOf(older.id, newer.id), repository.list(ACCOUNT_A).map { it.id })
        assertEquals(2, repository.pending(ACCOUNT_A).size)
    }

    @Test
    fun purge_clears_account() = runBlocking {
        repository.create(ACCOUNT_A, MemoryKind.FACT, "Lives in Hangzhou")
        repository.create(ACCOUNT_A, MemoryKind.FACT, "Has a cat")
        val kept = repository.create(ACCOUNT_B, MemoryKind.FACT, "Lives in Shanghai")
        val deviceId = repository.deviceId()

        // Clearing a partition goes through exactly this call.
        db.memoryItemDao().deleteByAccount(ACCOUNT_A)

        assertTrue(repository.list(ACCOUNT_A).isEmpty())
        assertTrue(repository.pending(ACCOUNT_A).isEmpty())
        assertEquals(listOf(kept), repository.list(ACCOUNT_B))
        assertEquals("the device id is not per account and survives clearing a partition", deviceId, repository.deviceId())
    }

    @Test
    fun migration_diff_zero() = runBlocking {
        seedOldClientPrefs()

        val result = repository.reconcileLegacy(FIXTURE_UID)

        // Fixture legacySyncCases.not_migrated_creates_and_writes_digest: one item each for memoryText and Anti-Forget, with deterministic ids.
        val items = repository.list(FIXTURE_UID)
        assertEquals(setOf(MEMORY_TEXT_ITEM_ID, ANTI_FORGET_ITEM_ID), items.map { it.id }.toSet())
        assertEquals(setOf(MEMORY_TEXT_MUTATION_ID, ANTI_FORGET_MUTATION_ID), items.map { it.mutationId }.toSet())
        assertEquals(items, repository.pending(FIXTURE_UID))
        assertEquals(result.create.map { it.id }.toSet(), items.map { it.id }.toSet())

        // Zero-diff migration: the compiled result matches the original memoryText exactly and only the digest is added; the Anti-Forget preferences are untouched.
        assertEquals("I write novels.", pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertEquals(MemoryItems.compileLegacy(FIXTURE_UID, items).memoryText, pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertEquals(MIGRATED_DIGEST, pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID))
        assertEquals("true", pref(AppPreferenceKeys.MEMORY_ITEMS_MIGRATED, FIXTURE_UID))
        assertEquals("true", pref(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, FIXTURE_UID))
        assertEquals("Always answer in Arabic.", pref(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, FIXTURE_UID))
        // Text unchanged (textChanged = false): only the local digest is filled in and memoryUpdatedAt is not refreshed.
        assertEquals(false, result.writePrefs?.textChanged)
        assertEquals("2026-10-01T00:00:00Z", pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID))
    }

    @Test
    fun digest_only_write_stays_local() = runBlocking {
        // Fixture legacySyncCases.fresh_device_empty_prefs_fills_digest_locally: a new device has no preferences at all before its first pull.
        val result = repository.reconcileLegacy(FIXTURE_UID)

        assertEquals(false, result.writePrefs?.textChanged)
        assertTrue(repository.list(FIXTURE_UID).isEmpty())
        assertEquals(EMPTY_DIGEST, pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID))
        assertEquals("true", pref(AppPreferenceKeys.MEMORY_ITEMS_MIGRATED, FIXTURE_UID))
        // memoryText / memoryUpdatedAt are not written, so an empty string never overwrites an existing memoryText.
        assertNull(pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertNull(pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID))

        // A local write that leaves the compiled result unchanged is likewise kept local.
        val created = repository.create(FIXTURE_UID, MemoryKind.FACT, "Lives in Hangzhou")
        repository.setPaused(FIXTURE_UID, created.id, paused = true)
        tick()
        repository.edit(FIXTURE_UID, created.id, "Lives in Shanghai")
        assertEquals("", pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertEquals(EMPTY_DIGEST, pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID))
    }

    @Test
    fun text_change_bumps_updated_at() = runBlocking {
        seedOldClientPrefs()
        repository.reconcileLegacy(FIXTURE_UID)
        tick()

        repository.create(FIXTURE_UID, MemoryKind.PREFERENCE, "Concise answers.")

        val expected = "I write novels.\n\nConcise answers."
        assertEquals(expected, pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertEquals(NEW_CLIENT_DIGEST, pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID))
        assertEquals(clock.toString(), pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID))
    }

    @Test
    fun migration_idempotent_two_devices() = runBlocking {
        val otherDb = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        try {
            var otherCounter = 0
            val other = MemoryItemRepository(
                dao = otherDb.memoryItemDao(),
                preferenceDao = otherDb.preferenceDao(),
                preferences = preferencesFor(otherDb),
                now = { clock },
                newId = { "9999999%d-aaaa-4bbb-8ccc-dddddddddddd".format(++otherCounter) },
            )
            seedOldClientPrefs()
            seedOldClientPrefs(otherDb)

            repository.reconcileLegacy(FIXTURE_UID)
            other.reconcileLegacy(FIXTURE_UID)

            // Two devices each migrate the same old preferences: id / mutationId / text match, only deviceId differs.
            val mine = repository.list(FIXTURE_UID)
            val theirs = other.list(FIXTURE_UID)
            assertEquals(mine.map { it.copy(deviceId = "") }, theirs.map { it.copy(deviceId = "") })
            assertNotEquals(mine.first().deviceId, theirs.first().deviceId)

            // Running it again does nothing.
            val updatedAt = pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID)
            tick()
            val again = repository.reconcileLegacy(FIXTURE_UID)
            assertTrue(again.create.isEmpty() && again.update.isEmpty())
            assertNull(again.writePrefs)
            assertEquals(mine, repository.list(FIXTURE_UID))
            assertEquals(updatedAt, pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID))
        } finally {
            otherDb.close()
        }
    }

    @Test
    fun dual_write_compile() = runBlocking {
        val first = repository.create(FIXTURE_UID, MemoryKind.FACT, "Lives in Hangzhou")
        tick()
        val second = repository.create(FIXTURE_UID, MemoryKind.PREFERENCE, "Likes short answers")
        tick()
        val third = repository.create(FIXTURE_UID, MemoryKind.INSTRUCTION, "Answer in Chinese")
        tick()
        repository.setPaused(FIXTURE_UID, second.id, paused = true)

        val expected = "${first.content}\n\n${third.content}"
        assertEquals(expected, pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertEquals(mcpSha256Hex(expected), pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID))
        assertEquals(clock.toString(), pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID))
        assertEquals("true", pref(AppPreferenceKeys.MEMORY_ITEMS_MIGRATED, FIXTURE_UID))
        // The Anti-Forget fields are no longer written.
        assertNull(pref(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, FIXTURE_UID))
        assertNull(pref(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, FIXTURE_UID))

        // A write that leaves the compiled result unchanged does not dual-write: memoryUpdatedAt stays.
        val updatedAt = pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID)
        tick()
        repository.edit(FIXTURE_UID, first.id, first.content)
        assertEquals(updatedAt, pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID))

        // Recompiled after a delete.
        tick()
        repository.delete(FIXTURE_UID, first.id)
        assertEquals(third.content, pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
    }

    @Test
    fun old_client_edit_flows_back() = runBlocking {
        seedOldClientPrefs()
        repository.reconcileLegacy(FIXTURE_UID)
        tick()

        // The old settings page (or an older client) changed memoryText: no digest.
        val edited = "I write novels.\n\nI live in Lisbon."
        preferences.saveMemory(edited, antiForgetEnabled = true, antiForgetText = "Always answer in Arabic.")
        tick()
        val result = repository.reconcileLegacy(FIXTURE_UID)

        assertEquals(listOf(MEMORY_TEXT_ITEM_ID), result.update.map { it.id })
        val item = repository.get(FIXTURE_UID, MEMORY_TEXT_ITEM_ID)!!
        assertEquals(edited, item.content)
        assertEquals(MemoryStatus.ACTIVE, item.status)
        assertEquals(item.revision, item.baseRevision)
        assertNotEquals(MEMORY_TEXT_MUTATION_ID, item.mutationId)
        assertTrue(repository.pending(FIXTURE_UID).any { it.id == MEMORY_TEXT_ITEM_ID && it.content == edited })
        // After the flow-back the compiled result matches memoryText and only the digest is added.
        assertEquals(edited, pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertEquals(mcpSha256Hex(edited), pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID))

        // An older client clears memoryText: the memoryText item gets a tombstone, with deletedAt set to the current time.
        tick()
        preferences.saveMemory("", antiForgetEnabled = false, antiForgetText = "")
        repository.reconcileLegacy(FIXTURE_UID)
        val tombstone = repository.get(FIXTURE_UID, MEMORY_TEXT_ITEM_ID)!!
        assertEquals(MemoryStatus.DELETED, tombstone.status)
        assertEquals(clock.toString(), tombstone.deletedAt)
    }

    @Test
    fun prefs_from_new_client_not_migrated() = runBlocking {
        // Fixture legacySyncCases.not_migrated_but_prefs_written_by_new_client: another new client has already migrated and written a digest.
        val text = "I write novels.\n\nConcise answers."
        setPref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID, text)
        setPref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID, NEW_CLIENT_DIGEST)
        setPref(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, FIXTURE_UID, "true")
        setPref(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, FIXTURE_UID, "Always answer in Arabic.")

        val result = repository.reconcileLegacy(FIXTURE_UID)

        assertTrue(result.create.isEmpty() && result.update.isEmpty())
        assertNull(result.writePrefs)
        assertTrue(repository.list(FIXTURE_UID).isEmpty())
        assertEquals("true", pref(AppPreferenceKeys.MEMORY_ITEMS_MIGRATED, FIXTURE_UID))
        assertEquals(text, pref(AppPreferenceKeys.MEMORY_TEXT, FIXTURE_UID))
        assertEquals(NEW_CLIENT_DIGEST, pref(AppPreferenceKeys.MEMORY_TEXT_DIGEST, FIXTURE_UID))
        assertNull(pref(AppPreferenceKeys.MEMORY_UPDATED_AT, FIXTURE_UID))
    }

    @Test
    fun unknown_status_falls_back_to_paused() = runBlocking {
        val created = repository.create(ACCOUNT_A, MemoryKind.FACT, "Lives in Hangzhou")
        val row = db.memoryItemDao().get(ACCOUNT_A, created.id)!!
        db.memoryItemDao().upsert(row.copy(status = "archived", kind = "habit"))

        val read = repository.get(ACCOUNT_A, created.id)!!
        assertEquals(MemoryStatus.PAUSED, read.status)
        assertEquals(MemoryKind.FACT, read.kind)
    }

    @Test
    fun legacy_reconcile_runs_on_account_switch_and_memory_text_change() = runBlocking {
        seedOldClientPrefs()
        val accountIds = MutableStateFlow(FIXTURE_UID)
        // Each reconcileLegacy records one (account, succeeded) entry; the first reconcile for ACCOUNT_B throws.
        val events = Channel<Pair<String, Boolean>>(Channel.UNLIMITED)
        var failNextB = true
        val spy = spyk(repository)
        coEvery { spy.reconcileLegacy(any()) } coAnswers {
            val accountId = firstArg<String>()
            if (accountId == ACCOUNT_B && failNextB) {
                failNextB = false
                events.send(accountId to false)
                throw IllegalStateException("reconcile failed once")
            }
            // Delegate to the original instance: mockk callOriginal leaks COROUTINE_SUSPENDED for a really suspending function.
            repository.reconcileLegacy(accountId).also { events.send(accountId to true) }
        }
        suspend fun awaitReconcile(accountId: String, ok: Boolean, done: suspend () -> Boolean = { true }) =
            withTimeout(10_000) {
                do {
                    val event = events.receive()
                } while (event != (accountId to ok) || !done())
            }
        val job = launch(Dispatchers.IO) { spy.runLegacyReconcile(accountIds) }
        try {
            // Reconciles on activation: old preferences are migrated into items.
            awaitReconcile(FIXTURE_UID, ok = true) { spy.get(FIXTURE_UID, MEMORY_TEXT_ITEM_ID) != null }

            // memoryText of this account changes (old settings page / older client): reconcile again, and the edit flows back into the items.
            val edited = "I write novels.\n\nI live in Lisbon."
            preferences.saveMemory(edited, antiForgetEnabled = true, antiForgetText = "Always answer in Arabic.")
            awaitReconcile(FIXTURE_UID, ok = true) { spy.get(FIXTURE_UID, MEMORY_TEXT_ITEM_ID)?.content == edited }

            // Switching account reconciles; a failure this time does not stop the listener.
            setPref(AppPreferenceKeys.MEMORY_TEXT, ACCOUNT_B, "B writes poems.")
            accountIds.value = ACCOUNT_B
            awaitReconcile(ACCOUNT_B, ok = false)
            assertTrue(spy.list(ACCOUNT_B).isEmpty())

            // memoryText changes again after the failure: still listening, migrates as usual.
            setPref(AppPreferenceKeys.MEMORY_TEXT, ACCOUNT_B, "B writes short poems.")
            awaitReconcile(ACCOUNT_B, ok = true) { spy.list(ACCOUNT_B).any { it.content == "B writes short poems." } }
            assertTrue(job.isActive)
        } finally {
            job.cancelAndJoin()
        }
    }

    private companion object {
        const val ACCOUNT_A = "user-a"
        const val ACCOUNT_B = "user-b"
        // uid and expected values of legacySyncCases in shared/context-contracts/memory-items.v2.json.
        const val FIXTURE_UID = "uid_7Hq2"
        const val MEMORY_TEXT_ITEM_ID = "075636ba-b7ce-5cb8-9371-c0c15d207027"
        const val MEMORY_TEXT_MUTATION_ID = "83bb7854-f957-5040-9a4d-b91bfe0d1f94"
        const val ANTI_FORGET_ITEM_ID = "25bdfec0-ba55-5f41-98e6-ebbc6a9b8b5b"
        const val ANTI_FORGET_MUTATION_ID = "39c4cd59-f318-5910-8d2f-4a329b86a6b1"
        const val MIGRATED_DIGEST = "e868d00ae29a99d00e8096258e07f5a446aa38070025f17c7491eaf6523b36e4"
        const val EMPTY_DIGEST = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        const val NEW_CLIENT_DIGEST = "31c83f7f76912791394836e31a51c6fb40449b67adc93ead6834bc50abe9b7a8"
    }
}
