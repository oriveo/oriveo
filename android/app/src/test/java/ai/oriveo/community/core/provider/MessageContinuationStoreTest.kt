package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.dao.MessageContinuationDao
import ai.oriveo.community.core.data.entity.MessageContinuationEntity
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.io.File

class MessageContinuationStoreTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun `network failure retains state until successful acknowledgement`() = runTest {
        val dao = FakeDao()
        val store = MessageContinuationStore(dao, json)
        val state = JsonObject(mapOf("completedMessages" to kotlinx.serialization.json.JsonArray(emptyList())))
        store.save("a", "c", "m", "tool_loop", state)

        val first = requireNotNull(store.loadForExplicit("a", "m"))
        assertEquals(state, first.state)
        assertEquals("failed request must remain retryable", state, store.loadForExplicit("a", "m")?.state)
        store.acknowledge(first)
        assertNull(store.loadForExplicit("a", "m"))
    }

    @Test fun `acknowledging an older snapshot cannot delete a newer producer state`() = runTest {
        val dao = FakeDao()
        val store = MessageContinuationStore(dao, json)
        val old = JsonObject(mapOf("previousResponseId" to JsonPrimitive("old")))
        // Deliberately write the exact same payload immediately: uniqueness must come from the
        // store's monotonic revision, not wall-clock millisecond or stateJson differences.
        val fresh = old
        store.save("a", "c", "m", "previous_id", old)
        val loaded = requireNotNull(store.loadForExplicit("a", "m"))
        store.save("a", "c", "m", "previous_id", fresh)

        assertEquals(false, store.acknowledge(loaded))
        assertEquals(fresh, store.loadForExplicit("a", "m")?.state)
    }

    @Test fun `restart interrupted and corrupt state all restart clean and delete poison row`() = runTest {
        val dao = FakeDao()
        val firstProcess = MessageContinuationStore(dao, json)
        firstProcess.save("a", "c", "previous", "previous_id", JsonObject(mapOf("previousResponseId" to JsonPrimitive("resp_1"))))
        assertNull("process token mismatch", MessageContinuationStore(dao, json).loadForExplicit("a", "previous"))
        assertNull(dao.get("a", "previous"))

        listOf("tool_loop", "replay_blocks", "replay_reasoning").forEach { kind ->
            val id = "$kind-restart"
            firstProcess.save("a", "c", id, kind, JsonObject(mapOf("opaque" to JsonPrimitive(kind))))
            assertNull("$kind also rejects process restart", MessageContinuationStore(dao, json).loadForExplicit("a", id))
        }

        firstProcess.save("a", "c", "background", "tool_loop", JsonObject(mapOf("completedMessages" to kotlinx.serialization.json.JsonArray(emptyList()))))
        firstProcess.markInterrupted("a", "background")
        assertNull("background rounds never resume", firstProcess.loadForExplicit("a", "background"))
        assertNull(dao.get("a", "background"))

        dao.upsert(MessageContinuationEntity("a", "corrupt", "c", "tool_loop", null, "not-json", false, 1))
        assertNull(firstProcess.loadForExplicit("a", "corrupt"))
        assertNull(dao.get("a", "corrupt"))
    }

    @Test fun `first store access purges every stale process row`() = runTest {
        val dao = FakeDao()
        repeat(4) { index ->
            dao.upsert(MessageContinuationEntity("a", "old-$index", "c", "tool_loop", "old-process", "{}", false, index.toLong()))
        }

        val current = MessageContinuationStore(dao, json)
        current.save("a", "c", "current", "tool_loop", JsonObject(emptyMap()))

        assertEquals(listOf("current"), dao.listForAccount("a").map { it.messageId })
    }

    @Test fun `conversation lifecycle deletion removes only owned sidecars`() = runTest {
        val dao = FakeDao()
        val store = MessageContinuationStore(dao, json)
        store.save("a", "c1", "m1", "tool_loop", JsonObject(emptyMap()))
        store.save("a", "c2", "m2", "tool_loop", JsonObject(emptyMap()))
        dao.deleteForConversation("a", "c1")
        assertNull(dao.get("a", "m1"))
        assertNotNull(dao.get("a", "m2"))
    }

    @Test fun `backup and device transfer exclude continuation database wal and shm`() {
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val legacy = File(root, "android/app/src/main/res/xml/backup_rules.xml").readText()
        val modern = File(root, "android/app/src/main/res/xml/data_extraction_rules.xml").readText()
        listOf("message_continuations.db", "message_continuations.db-wal", "message_continuations.db-shm").forEach { path ->
            assertEquals("legacy cloud backup excludes $path", 1, Regex("domain=\"database\" path=\"$path\"").findAll(legacy).count())
            assertEquals("cloud plus device-transfer exclude $path", 2, Regex("domain=\"database\" path=\"$path\"").findAll(modern).count())
        }
    }

    private class FakeDao : MessageContinuationDao {
        private val rows = linkedMapOf<Pair<String, String>, MessageContinuationEntity>()
        override suspend fun upsert(entity: MessageContinuationEntity) { rows[entity.accountId to entity.messageId] = entity }
        override suspend fun get(accountId: String, messageId: String) = rows[accountId to messageId]
        override suspend fun delete(accountId: String, messageId: String) { rows.remove(accountId to messageId) }
        override suspend fun deleteOtherProcessSessions(currentToken: String) {
            rows.entries.removeAll { it.value.processSessionToken != currentToken }
        }
        override suspend fun deleteMessages(accountId: String, messageIds: List<String>) { messageIds.forEach { rows.remove(accountId to it) } }
        override suspend fun deleteIfUnchanged(accountId: String, messageId: String, updatedAt: Long, processSessionToken: String, stateJson: String): Int {
            val key = accountId to messageId
            val row = rows[key]
            return if (row?.updatedAt == updatedAt && row.processSessionToken == processSessionToken &&
                row.stateJson == stateJson && !row.interrupted
            ) { rows.remove(key); 1 } else 0
        }
        override suspend fun markInterrupted(accountId: String, messageId: String, updatedAt: Long) {
            val key = accountId to messageId
            rows[key]?.let { rows[key] = it.copy(interrupted = true, updatedAt = updatedAt) }
        }
        override suspend fun deleteForConversation(accountId: String, conversationId: String) {
            rows.entries.removeAll { it.value.accountId == accountId && it.value.conversationId == conversationId }
        }
        override suspend fun listForAccount(accountId: String) = rows.values.filter { it.accountId == accountId }
    }
}
