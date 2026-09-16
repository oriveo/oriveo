package ai.oriveo.community.core.data.repository.chat

import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.model.ChatMessageState
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins down [messageWindowSnapshotsEquivalent]: a checkpoint written while a message is generating
 * must not refresh the chat window.
 *
 * Background: a long answer writes its partial text back into `messages.text` every few thousand
 * characters or every minute, and the same checkpoint may carry `reasoningText` with it. A bare
 * `distinctUntilChanged()` compares whole `MessageEntity` values, so one changed column sends the
 * entire window (sixty rows) back through `toDomain()` — and the message mapper decodes several
 * JSON fields per row. The new list then hands the lazy list's item provider new instances, so
 * every visible cell recomposes along with its markdown subtree. None of that reaches the screen
 * anyway: while generating, the UI reads the streaming flows, not the row.
 *
 * The other half of this suite matters just as much: **do not ignore too much**. Swallowing
 * progress or status columns leaves the user staring at a spinner that never advances, so every
 * column other than the checkpoint ones has to pass through.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MessageWindowCheckpointEqualityTest {

    private val conversationId = "CCCCCCCC-0000-0000-0000-000000000003"

    // ── The predicate itself ────────────────────────────────────────────────────

    @Test
    fun `generating checkpoint columns are ignored`() {
        val before = listOf(delivered(0), generating(1, text = "Hel"))
        val after = listOf(
            delivered(0),
            generating(1, text = "Hello world", reasoning = "thinking…"),
        )

        assertTrue(
            "a partial body or reasoning checkpoint must not refresh the window",
            messageWindowSnapshotsEquivalent(before, after),
        )
    }

    @Test
    fun `finalize always passes and carries the settled text in`() {
        val before = listOf(generating(0, text = "Hel"))
        val after = listOf(generating(0, text = "Hello world").copy(state = ChatMessageState.Delivered.name))

        assertFalse(
            "state takes part in the comparison, so finalising always passes and brings the final text in",
            messageWindowSnapshotsEquivalent(before, after),
        )
    }

    @Test
    fun `checkpoint columns take part in the comparison again once the message settled`() {
        val settled = delivered(0).copy(text = "Hello")
        val edited = settled.copy(text = "Hello, edited")

        assertFalse(
            "a body change outside the generating state really does need to reach the screen (inline edits, restores)",
            messageWindowSnapshotsEquivalent(listOf(settled), listOf(edited)),
        )
    }

    /**
     * Ignoring too much is the easy mistake here, so every column that must still pass through
     * while generating is nailed down one by one. The implementation is `copy(checkpoint columns)
     * == new`, which puts new columns on the passing side automatically, but the existing ones are
     * product-visible state and deserve explicit cases.
     */
    @Test
    fun `every other column still refreshes the window while generating`() {
        val base = generating(0, text = "Hel")
        val mutations: List<Pair<String, MessageEntity>> = listOf(
            "citationsJson" to base.copy(citationsJson = """[{"url":"https://example.com"}]"""),
            "attachmentsJson" to base.copy(attachmentsJson = """[{"id":"a1"}]"""),
            "quoteContextJson" to base.copy(quoteContextJson = """{"selectedText":"x"}"""),
            "errorTitle" to base.copy(errorTitle = "boom"),
            "errorDetail" to base.copy(errorDetail = "detail"),
            "estimatedCost" to base.copy(estimatedCost = 0.42),
            "inputTokens" to base.copy(inputTokens = 12),
            "outputTokens" to base.copy(outputTokens = 34),
            "cachedInputTokens" to base.copy(cachedInputTokens = 5),
            "costSource" to base.copy(costSource = "UPSTREAM"),
            "reasoningDurationMs" to base.copy(reasoningDurationMs = 1_200L),
            "modelID" to base.copy(modelID = "gpt-5"),
            "servedModelID" to base.copy(servedModelID = "gpt-5-served"),
            "capabilityExecutionResultsJson" to base.copy(capabilityExecutionResultsJson = "[]"),
            "unhandledToolCallsJson" to base.copy(unhandledToolCallsJson = "[]"),
            "toolFallbackNotice" to base.copy(toolFallbackNotice = "no_executor"),
            "customRetryWithoutFieldsAvailable" to base.copy(customRetryWithoutFieldsAvailable = true),
            "sortOrder" to base.copy(sortOrder = base.sortOrder + 1),
        )

        mutations.forEach { (column, mutated) ->
            assertFalse(
                "$column was ignored while generating — ignoring too much is how progress state gets swallowed",
                messageWindowSnapshotsEquivalent(listOf(base), listOf(mutated)),
            )
        }
    }

    @Test
    fun `list shape changes always pass`() {
        val one = listOf(generating(0, text = "Hel"))
        assertFalse("a new message entering the window must pass", messageWindowSnapshotsEquivalent(one, one + delivered(1)))
        assertFalse("so must a deletion", messageWindowSnapshotsEquivalent(one + delivered(1), one))
        assertFalse(
            "a different message at the same position (the window scrolled) must pass",
            messageWindowSnapshotsEquivalent(one, listOf(generating(1, text = "Hel"))),
        )
    }

    // ── End to end: the window loader stays still across checkpoints ────────────

    @Test
    fun `persisting a partial while generating leaves the window state untouched`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = CheckpointStore()
        store.replace(listOf(delivered(0), generating(1, text = "Hel")))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )
        loader.bind(TestScope(testScheduler), conversationId)
        testScheduler.advanceUntilIdle()

        val beforeState = loader.state.value
        val beforeMessages = beforeState.messages
        assertEquals(2, beforeMessages.size)

        // Three checkpoints in a row: body only, then body plus reasoning.
        store.replace(listOf(delivered(0), generating(1, text = "Hello")))
        testScheduler.advanceUntilIdle()
        store.replace(listOf(delivered(0), generating(1, text = "Hello world", reasoning = "thinking…")))
        testScheduler.advanceUntilIdle()
        store.replace(listOf(delivered(0), generating(1, text = "Hello world!", reasoning = "thinking…")))
        testScheduler.advanceUntilIdle()

        assertSame(
            "the window must not change identity: a new List instance means the whole message list recomposes",
            beforeMessages,
            loader.state.value.messages,
        )
        assertSame("the whole State should stay the same instance", beforeState, loader.state.value)
        assertEquals(
            "the window still holds the pre-checkpoint body (the UI reads the streaming flow, not this)",
            "Hel",
            loader.state.value.messages[1].text,
        )
    }

    @Test
    fun `settling the message brings the final text into the window`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = CheckpointStore()
        store.replace(listOf(delivered(0), generating(1, text = "Hel")))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )
        loader.bind(TestScope(testScheduler), conversationId)
        testScheduler.advanceUntilIdle()
        val beforeMessages = loader.state.value.messages

        store.replace(listOf(delivered(0), generating(1, text = "Hello world").settled()))
        testScheduler.advanceUntilIdle()

        assertNotSame(beforeMessages, loader.state.value.messages)
        assertEquals("Hello world", loader.state.value.messages[1].text)
        assertEquals(ChatMessageState.Delivered, loader.state.value.messages[1].state)
    }

    @Test
    fun `citations and cost still refresh the window while generating`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = CheckpointStore()
        store.replace(listOf(generating(0, text = "")))
        val loader = MessageWindowLoader(
            messageDao = makeDao(store),
            windowSize = 60,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )
        loader.bind(TestScope(testScheduler), conversationId)
        testScheduler.advanceUntilIdle()
        val initial = loader.state.value.messages

        store.replace(
            listOf(
                generating(0, text = "").copy(
                    citationsJson = """[{"url":"https://example.com","title":"Example"}]""",
                ),
            ),
        )
        testScheduler.advanceUntilIdle()
        val afterCitations = loader.state.value.messages
        assertNotSame("a change in citations must refresh the window", initial, afterCitations)

        store.replace(
            listOf(
                generating(0, text = "").copy(
                    citationsJson = """[{"url":"https://example.com","title":"Example"}]""",
                    estimatedCost = 0.12,
                ),
            ),
        )
        testScheduler.advanceUntilIdle()
        assertNotSame("a change in cost must refresh the window", afterCitations, loader.state.value.messages)
    }

    // ── Structure: the predicate has to gate before toDomain ────────────────────

    @Test
    fun `the comparator gates the room flow before toDomain runs`() {
        val source = File(
            "src/main/java/ai/oriveo/community/core/data/repository/chat/MessageWindowLoader.kt",
        ).readText()

        assertFalse(
            "a bare distinctUntilChanged() compares whole entities, so one checkpoint sends the whole window through toDomain",
            source.contains(".distinctUntilChanged()"),
        )
        assertEquals(
            "both the tail window and the anchored window have to use the same predicate",
            2,
            Regex("""\.distinctUntilChanged\(::messageWindowSnapshotsEquivalent\)""").findAll(source).count(),
        )
        // The gate has to take effect before handleObservedWindow, which is where toDomain runs:
        // sixty rows times several JSON decodes is the whole cost, so filtering afterwards pays it
        // for nothing.
        val gateAt = source.indexOf(".distinctUntilChanged(::messageWindowSnapshotsEquivalent)")
        val collectAt = source.indexOf("handleObservedWindow(normalized, entities)")
        assertTrue("the predicate must come before the collect into handleObservedWindow", gateAt in 1 until collectAt)
    }

    @Test
    fun `the partial flush comment no longer claims a single item recomposition`() {
        val source = File(
            "src/main/java/ai/oriveo/community/core/data/repository/ChatRepository.kt",
        ).readText()

        assertFalse(
            "that claim contradicts what the message list itself relies on",
            source.contains("re-lays out the list"),
        )
        assertTrue(
            "it also has to point at the predicate that really stops it, or the next reader reasons from the old comment",
            source.contains("messageWindowSnapshotsEquivalent"),
        )
    }

    // ── fixtures ────────────────────────────────────────────────────────────────

    private fun delivered(sortOrder: Int) = entity(sortOrder, ChatMessageState.Delivered.name)

    private fun generating(
        sortOrder: Int,
        text: String,
        reasoning: String? = null,
    ) = entity(sortOrder, ChatMessageState.Generating.name).copy(
        text = text,
        reasoningText = reasoning,
    )

    private fun MessageEntity.settled() = copy(state = ChatMessageState.Delivered.name)

    private fun entity(sortOrder: Int, state: String) = MessageEntity(
        id = "MSG-%05d".format(sortOrder),
        conversationId = conversationId,
        role = if (sortOrder % 2 == 0) "User" else "Assistant",
        text = "message-$sortOrder",
        providerID = null,
        providerKind = "OpenAI",
        providerName = "OpenAI",
        modelID = null,
        modelName = "gpt-test",
        servedModelID = null,
        estimatedCost = 0.0,
        state = state,
        errorTitle = null,
        errorDetail = null,
        attachmentsJson = null,
        createdAt = sortOrder.toLong(),
        sortOrder = sortOrder,
    )

    /** In-memory stand-in for the messages table: only the tail window observe and boundary probes are needed. */
    private class CheckpointStore {
        private var rows: List<MessageEntity> = emptyList()
        private val signal = MutableSharedFlow<Unit>(replay = 1, extraBufferCapacity = 64)

        init {
            signal.tryEmit(Unit)
        }

        fun replace(messages: List<MessageEntity>) {
            rows = messages
            signal.tryEmit(Unit)
        }

        fun observeWindow(limit: Int) = flow {
            signal.collect { emit(rows.sortedWith(compareBy({ it.sortOrder }, { it.id })).takeLast(limit)) }
        }
    }

    private fun makeDao(store: CheckpointStore): MessageDao {
        val dao = mockk<MessageDao>(relaxed = true)
        every { dao.observeLatestMessageWindow(any(), any(), any()) } answers {
            store.observeWindow(thirdArg())
        }
        coEvery { dao.existsBefore(any(), any(), any(), any()) } returns false
        coEvery { dao.existsAfter(any(), any(), any(), any()) } returns false
        return dao
    }
}
