package ai.oriveo.community.core.data.repository.chat

import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.entity.MessageEntity
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * State-machine tests for MessageWindowLoader, mirroring the key scenarios from
 * the iOS MessageWindowLoaderTests suite.
 *
 * Design:
 *  - Uses a relaxed mockk DAO plus an in-memory [MutableSharedFlow] instead of a real Room
 *    database, so the suite runs as a plain JVM test with no Android runtime
 *  - Keyset pagination semantics (fetchMessagesBefore / existsBefore) are simulated by
 *    [InMemoryMessageStore]
 *  - All IO/CPU dispatchers are injected with [StandardTestDispatcher] so runTest can advance
 *    virtual time
 *
 * SQL correctness is covered by Room's compile-time query validation; this suite covers the
 * state machine's merge, boundary, and history-paging rules.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MessageWindowLoaderTest {

    private val convA = "AAAAAAAA-0000-0000-0000-000000000001"
    private val convB = "BBBBBBBB-0000-0000-0000-000000000002"

    @Test
    fun `bind emits tail window with hasMoreAbove true when conversation exceeds limit`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 150, prefix = "M"))
        val dao = makeDao(store)
        val loader = MessageWindowLoader(
            messageDao = dao,
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals(60, state.messages.size)
        assertEquals("M-90", state.messages.first().text)
        assertEquals("M-149", state.messages.last().text)
        assertTrue(state.hasMoreAbove)
        assertFalse(state.hasMoreBelow)
        assertFalse(state.isInitialLoading)
    }

    @Test
    fun `bind hasMoreAbove false when conversation smaller than window`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 5, prefix = "S"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals(5, state.messages.size)
        assertFalse(state.hasMoreAbove)
        assertEquals("S-0", state.messages.first().text)
        assertEquals("S-4", state.messages.last().text)
    }

    @Test
    fun `bind dedupes message ids that collide after UUID normalization`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        val lowerId = "ca4b5067-834c-4729-8f8c-c133ca7fb0ea"
        val upperId = lowerId.uppercase()
        store.replace(
            convA,
            listOf(
                makeEntity(convA, sortOrder = 0, idPrefix = "D", text = "stale").copy(id = lowerId),
                makeEntity(convA, sortOrder = 1, idPrefix = "D", text = "current").copy(id = upperId),
            ),
        )
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()

        val messages = loader.state.value.messages
        assertEquals(1, messages.size)
        assertEquals(upperId, messages.single().id)
        assertEquals("current", messages.single().text)
    }

    @Test
    fun `extendUpward prepends earlier messages`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 200, prefix = "E"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertEquals("E-140", loader.state.value.messages.first().text)

        loader.extendUpward()
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals(120, state.messages.size)
        assertEquals("E-80", state.messages.first().text)
        // tail is unchanged (window tail + extension head form one continuous run)
        assertEquals("E-199", state.messages.last().text)
        assertTrue(state.hasMoreAbove)
    }

    @Test
    fun `repeated extendUpward terminates with hasMoreAbove false`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 100, prefix = "U"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()

        loader.extendUpward()
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals(100, state.messages.size)
        assertEquals("U-0", state.messages.first().text)
        assertFalse(state.hasMoreAbove)
    }

    @Test
    fun `extendUpward is noop when hasMoreAbove false`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 10, prefix = "N"))
        val dao = makeDao(store)
        val loader = MessageWindowLoader(
            messageDao = dao,
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertFalse(loader.state.value.hasMoreAbove)

        loader.extendUpward()
        testScheduler.advanceUntilIdle()

        // should not trigger any fetchMessagesBefore calls
        coVerify(exactly = 0) {
            dao.fetchMessagesBefore(any(), any(), any(), any(), any())
        }
        assertEquals(10, loader.state.value.messages.size)
    }

    @Test
    fun `applySnapshot preserves extension when head id changes`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        val initial = makeMessages(convA, count = 200, prefix = "P")
        store.replace(convA, initial)
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        // initial screen's last 60 = P-140..P-199
        assertEquals("P-140", loader.state.value.messages.first().text)

        // extend upward -> P-80..P-199, 120 total
        loader.extendUpward()
        testScheduler.advanceUntilIdle()
        val extensionHeadId = loader.state.value.messages.first().id
        assertEquals("P-80", loader.state.value.messages.first().text)

        // remote replaces P-140 (the tail window's head) with a new id + text, simulating LWW
        val mutated = initial.toMutableList()
        val original140 = mutated[140]
        mutated[140] = original140.copy(
            id = "REPLACED-140",
            text = "P-140-replaced",
        )
        store.replace(convA, mutated)
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        // the extension segment P-80..P-139 must be preserved (the core assertion)
        assertEquals(extensionHeadId, state.messages.first().id)
        assertTrue("extension segment still has P-100", state.messages.any { it.text == "P-100" })
        assertTrue("extension segment still has P-139", state.messages.any { it.text == "P-139" })
        assertTrue("new head P-140-replaced merged in", state.messages.any { it.text == "P-140-replaced" })
        assertEquals("P-199", state.messages.last().text)
    }

    /**
     * Regression test for a real crash: when SyncManager receives a remote change, it
     * re-sorts all messages by createdAt, which can shift a message living in the
     * extension segment into the tail window. The cut point only guarantees uniqueness
     * for the message at the cut itself, so the old copy left in the extension segment
     * ends up duplicating the new position from the snapshot -- two items share the same
     * id, and LazyColumn crashes with "Key ... was already used".
     */
    @Test
    fun `applySnapshot drops extension duplicates when sync reorders a message into the tail window`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        val initial = makeMessages(convA, count = 200, prefix = "P")
        store.replace(convA, initial)
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        loader.extendUpward()
        testScheduler.advanceUntilIdle()
        // after extending upward, P-80..P-199 (120 total), with P-100 in the extension segment
        assertEquals("P-80", loader.state.value.messages.first().text)
        assertTrue("P-100 is in the extension segment", loader.state.value.messages.any { it.text == "P-100" })

        // defensive re-sort: P-100's createdAt is actually the newest, so its sortOrder is corrected to the tail (id unchanged)
        val resorted = initial.toMutableList()
        val moved = resorted.removeAt(100).copy(sortOrder = 200, createdAt = 200L)
        resorted.add(moved)
        store.replace(convA, resorted)
        testScheduler.advanceUntilIdle()

        val messages = loader.state.value.messages
        assertEquals(
            "merged result must not contain duplicate ids (the LazyColumn key crash)",
            messages.size,
            messages.map { it.id }.distinct().size,
        )
        // extension segment is preserved; after re-sorting only the snapshot's copy of P-100 remains (at the tail)
        assertEquals("P-80", messages.first().text)
        assertEquals("P-100", messages.last().text)
        assertEquals(1, messages.count { it.text == "P-100" })
        assertTrue("extension segment still has P-139", messages.any { it.text == "P-139" })
    }

    @Test
    fun `applySnapshot fully diverged resets state`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 30, prefix = "D"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertEquals("D-0", loader.state.value.messages.first().text)

        // replace the whole batch with new UUIDs + text (an extremely rare full overwrite scenario)
        val replacements = (0 until 30).map { i ->
            makeEntity(convA, sortOrder = i, idPrefix = "X-uuid", text = "X-$i")
        }
        store.replace(convA, replacements)
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals(30, state.messages.size)
        assertEquals("X-0", state.messages.first().text)
        assertEquals("X-29", state.messages.last().text)
        assertTrue("a disjoint snapshot should trigger a full reset", state.messages.all { it.text.startsWith("X-") })
    }

    @Test
    fun `appended messages bubble through observe path`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 30, prefix = "S"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertEquals(30, loader.state.value.messages.size)

        // simulate streaming finalize: addMessage (new entries persisted)
        store.append(convA, makeEntity(convA, sortOrder = 30, idPrefix = "new", text = "new-token-1"))
        store.append(convA, makeEntity(convA, sortOrder = 31, idPrefix = "new", text = "new-token-2"))
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals(32, state.messages.size)
        assertEquals("new-token-2", state.messages.last().text)
    }

    @Test
    fun `rebind to other conversation does not leak state`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 30, prefix = "A"))
        store.replace(convB, makeMessages(convB, count = 50, prefix = "B"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertEquals("A-0", loader.state.value.messages.first().text)

        loader.bind(TestScope(testScheduler), convB)
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertTrue("B session messages are not mixed with A", state.messages.all { it.text.startsWith("B-") })
        assertEquals(50, state.messages.size)
    }

    @Test
    fun `stop clears messages and unbinds observation`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 10, prefix = "C"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertEquals(10, loader.state.value.messages.size)

        loader.stop()

        val state = loader.state.value
        assertNull(state.conversationId)
        assertTrue(state.messages.isEmpty())
        assertNull(state.earliestBoundary)
        assertFalse(state.hasMoreAbove)
    }

    @Test
    fun `observe emits empty messages when conversation cleared`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 20, prefix = "K"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertEquals(20, loader.state.value.messages.size)

        // remote deletes everything -> snapshot is empty
        store.replace(convA, emptyList())
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertTrue(state.messages.isEmpty())
        assertNull(state.earliestBoundary)
        assertFalse(state.hasMoreAbove)
    }

    @Test
    fun `loadAroundMessage centers existing local target and exposes below boundary`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 150, prefix = "A"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 11,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertEquals("A-139", loader.state.value.messages.first().text)

        val loaded = loader.loadAroundMessage(convA, "A-${convA.takeLast(6)}-00050")
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertTrue(loaded)
        assertEquals(11, state.messages.size)
        assertEquals("A-45", state.messages.first().text)
        assertEquals("A-50", state.messages[5].text)
        assertEquals("A-55", state.messages.last().text)
        assertTrue(state.hasMoreAbove)
        assertTrue(state.hasMoreBelow)
        assertFalse(state.isInitialLoading)
    }

    @Test
    fun `loadAroundMessage keeps the anchored window observable for adjacent appends`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 53, prefix = "O"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 11,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertTrue(loader.loadAroundMessage(convA, "O-${convA.takeLast(6)}-00050"))
        testScheduler.advanceUntilIdle()
        assertEquals("O-45", loader.state.value.messages.first().text)
        assertEquals("O-52", loader.state.value.messages.last().text)

        store.append(convA, makeEntity(convA, sortOrder = 53, idPrefix = "O", text = "O-53"))
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals("O-45", state.messages.first().text)
        assertEquals("O-53", state.messages.last().text)
        assertTrue(state.messages.any { it.text == "O-50" })
    }

    @Test
    fun `extendDownward appends newer messages after anchor window`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = InMemoryMessageStore()
        store.replace(convA, makeMessages(convA, count = 150, prefix = "D"))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 11,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )

        loader.bind(TestScope(testScheduler), convA)
        testScheduler.advanceUntilIdle()
        assertTrue(loader.loadAroundMessage(convA, "D-${convA.takeLast(6)}-00050"))
        testScheduler.advanceUntilIdle()
        assertEquals("D-55", loader.state.value.messages.last().text)
        assertTrue(loader.state.value.hasMoreBelow)

        loader.extendDownward()
        testScheduler.advanceUntilIdle()

        val state = loader.state.value
        assertEquals(22, state.messages.size)
        assertEquals("D-45", state.messages.first().text)
        assertEquals("D-66", state.messages.last().text)
        assertTrue(state.hasMoreAbove)
        assertTrue(state.hasMoreBelow)
    }

    // ──────────────────────────────────────────────────────────────────
    // Test helpers
    // ──────────────────────────────────────────────────────────────────

    private fun makeMessages(convId: String, count: Int, prefix: String): List<MessageEntity> =
        (0 until count).map { i ->
            makeEntity(
                conversationId = convId,
                sortOrder = i,
                idPrefix = prefix,
                text = "$prefix-$i",
            )
        }

    private fun makeEntity(
        conversationId: String,
        sortOrder: Int,
        idPrefix: String,
        text: String,
    ): MessageEntity = MessageEntity(
        id = "%s-%s-%05d".format(idPrefix, conversationId.takeLast(6), sortOrder),
        conversationId = conversationId,
        role = if (sortOrder % 2 == 0) "User" else "Assistant",
        text = text,
        providerID = null,
        providerKind = "OpenAI",
        providerName = "OpenAI",
        modelID = null,
        modelName = "gpt-test",
        servedModelID = null,
        estimatedCost = 0.0,
        state = "Delivered",
        errorTitle = null,
        errorDetail = null,
        attachmentsJson = null,
        createdAt = sortOrder.toLong(),
        sortOrder = sortOrder,
    )

    private fun makeDao(store: InMemoryMessageStore): MessageDao {
        val dao = mockk<MessageDao>(relaxed = true)
        every { dao.observeLatestMessageWindow(any(), any(), any()) } answers {
            val convId = secondArg<String>()
            val limit = thirdArg<Int>()
            store.observeWindow(convId, limit)
        }
        every { dao.observeMessageWindowAround(any(), any(), any(), any(), any()) } answers {
            store.observeWindowAround(
                conversationId = secondArg(),
                messageId = thirdArg(),
                beforeLimit = arg(3),
                afterLimit = arg(4),
            )
        }
        coEvery { dao.fetchMessagesBefore(any(), any(), any(), any(), any()) } answers {
            store.fetchBefore(
                conversationId = secondArg(),
                boundarySortOrder = thirdArg(),
                boundaryId = arg(3),
                limit = arg(4),
            )
        }
        coEvery { dao.fetchMessagesAfter(any(), any(), any(), any(), any()) } answers {
            store.fetchAfter(
                conversationId = secondArg(),
                boundarySortOrder = thirdArg(),
                boundaryId = arg(3),
                limit = arg(4),
            )
        }
        coEvery { dao.existsBefore(any(), any(), any(), any()) } answers {
            store.existsBefore(
                conversationId = secondArg(),
                boundarySortOrder = thirdArg(),
                boundaryId = arg(3),
            )
        }
        coEvery { dao.existsAfter(any(), any(), any(), any()) } answers {
            store.existsAfter(
                conversationId = secondArg(),
                boundarySortOrder = thirdArg(),
                boundaryId = arg(3),
            )
        }
        coEvery { dao.getByIdForConversation(any(), any(), any()) } answers {
            store.getByIdForConversation(
                conversationId = secondArg(),
                id = thirdArg(),
            )
        }
        return dao
    }

    /**
     * In-memory messages table simulating keyset pagination semantics.
     *
     * Writes via [replace] / [append] trigger [observeWindow] to re-emit;
     * fetchBefore / existsBefore stay consistent with [snapshot].
     */
    private class InMemoryMessageStore {
        private val byConv = mutableMapOf<String, MutableList<MessageEntity>>()
        private val signal = MutableSharedFlow<Unit>(replay = 1, extraBufferCapacity = 64)

        init {
            // emit once up front so observe immediately gets an empty snapshot
            signal.tryEmit(Unit)
        }

        fun replace(conversationId: String, messages: List<MessageEntity>) {
            byConv[conversationId] = messages.toMutableList()
            signal.tryEmit(Unit)
        }

        fun append(conversationId: String, message: MessageEntity) {
            byConv.getOrPut(conversationId) { mutableListOf() }.add(message)
            signal.tryEmit(Unit)
        }

        fun observeWindow(conversationId: String, limit: Int) =
            kotlinx.coroutines.flow.flow {
                signal.collect {
                    emit(snapshotWindow(conversationId, limit))
                }
            }

        fun observeWindowAround(
            conversationId: String,
            messageId: String,
            beforeLimit: Int,
            afterLimit: Int,
        ) = kotlinx.coroutines.flow.flow {
            signal.collect {
                emit(snapshotWindowAround(conversationId, messageId, beforeLimit, afterLimit))
            }
        }

        private fun snapshotWindow(conversationId: String, limit: Int): List<MessageEntity> {
            val all = byConv[conversationId].orEmpty()
                .sortedWith(compareBy({ it.sortOrder }, { it.id }))
            return all.takeLast(limit)
        }

        private fun snapshotWindowAround(
            conversationId: String,
            messageId: String,
            beforeLimit: Int,
            afterLimit: Int,
        ): List<MessageEntity> {
            val all = byConv[conversationId].orEmpty()
                .sortedWith(compareBy({ it.sortOrder }, { it.id }))
            val target = all.firstOrNull { it.id == messageId } ?: return emptyList()
            val before = all.filter {
                it.sortOrder < target.sortOrder || (it.sortOrder == target.sortOrder && it.id < target.id)
            }.takeLast(beforeLimit)
            val after = all.filter {
                it.sortOrder > target.sortOrder || (it.sortOrder == target.sortOrder && it.id > target.id)
            }.take(afterLimit)
            return before + target + after
        }

        fun fetchBefore(
            conversationId: String,
            boundarySortOrder: Int,
            boundaryId: String,
            limit: Int,
        ): List<MessageEntity> {
            val all = byConv[conversationId].orEmpty()
                .sortedWith(compareBy({ it.sortOrder }, { it.id }))
            return all.filter { it.sortOrder < boundarySortOrder || (it.sortOrder == boundarySortOrder && it.id < boundaryId) }
                .takeLast(limit)
        }

        fun existsBefore(
            conversationId: String,
            boundarySortOrder: Int,
            boundaryId: String,
        ): Boolean = byConv[conversationId].orEmpty().any {
            it.sortOrder < boundarySortOrder || (it.sortOrder == boundarySortOrder && it.id < boundaryId)
        }

        fun fetchAfter(
            conversationId: String,
            boundarySortOrder: Int,
            boundaryId: String,
            limit: Int,
        ): List<MessageEntity> {
            val all = byConv[conversationId].orEmpty()
                .sortedWith(compareBy({ it.sortOrder }, { it.id }))
            return all.filter { it.sortOrder > boundarySortOrder || (it.sortOrder == boundarySortOrder && it.id > boundaryId) }
                .take(limit)
        }

        fun existsAfter(
            conversationId: String,
            boundarySortOrder: Int,
            boundaryId: String,
        ): Boolean = byConv[conversationId].orEmpty().any {
            it.sortOrder > boundarySortOrder || (it.sortOrder == boundarySortOrder && it.id > boundaryId)
        }

        fun getByIdForConversation(conversationId: String, id: String): MessageEntity? =
            byConv[conversationId].orEmpty().firstOrNull { it.id == id }
    }
}
