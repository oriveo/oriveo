package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.chat.MessageWindowLoader
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ChatMessageWindowCoordinator: the conversation render flow, window paging (above / below / focus) and derived flow state.
 * The backend is the real [MessageWindowLoader] over an in-memory fake DAO (window of 2, conversation of 5); assertions come from the windows the loader actually produces.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatMessageWindowCoordinatorTest {

    private val convId = "00000000-0000-0000-0000-0000000000c1"
    private fun msgId(i: Int) = "00000000-0000-0000-0000-00000000000$i"

    /** Conversation rows (ascending by sortOrder); left empty in the focus-miss case and stored when hydrated. */
    private var rows: List<MessageEntity> = emptyList()

    private fun seed(count: Int = 5) {
        rows = (0 until count).map { i ->
            ChatMessage(
                id = msgId(i),
                role = if (i % 2 == 0) ChatRole.User else ChatRole.Assistant,
                text = "m$i",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "gpt",
                state = ChatMessageState.Delivered,
            ).toEntity("guest", convId, i)
        }
    }

    private fun before(so: Int, id: String) = rows.filter { it.sortOrder < so || (it.sortOrder == so && it.id < id) }
    private fun after(so: Int, id: String) = rows.filter { it.sortOrder > so || (it.sortOrder == so && it.id > id) }

    private val dao: MessageDao = mockk<MessageDao>(relaxed = true).also { dao ->
        every { dao.observeLatestMessageWindow(any(), any(), any()) } answers { flowOf(rows.takeLast(thirdArg())) }
        coEvery { dao.existsBefore(any(), any(), any(), any()) } answers { before(thirdArg(), arg(3)).isNotEmpty() }
        coEvery { dao.existsAfter(any(), any(), any(), any()) } answers { after(thirdArg(), arg(3)).isNotEmpty() }
        coEvery { dao.fetchMessagesBefore(any(), any(), any(), any(), any()) } answers {
            before(thirdArg(), arg(3)).takeLast(arg(4))
        }
        coEvery { dao.fetchMessagesAfter(any(), any(), any(), any(), any()) } answers {
            after(thirdArg(), arg(3)).take(arg(4))
        }
        coEvery { dao.getByIdForConversation(any(), any(), any()) } answers { rows.find { it.id == thirdArg<String>() } }
        every { dao.observeMessageWindowAround(any(), any(), any(), any(), any()) } answers {
            val index = rows.indexOfFirst { it.id == thirdArg<String>() }
            val beforeLimit = arg<Int>(3)
            val afterLimit = arg<Int>(4)
            flowOf(rows.subList(maxOf(0, index - beforeLimit), minOf(rows.size, index + afterLimit + 1)))
        }
    }

    private val repository = mockk<ConversationRepository>(relaxed = true).also { repo ->
        every { repo.createMessageWindowLoader() } answers {
            MessageWindowLoader(messageDao = dao, windowSize = 2, ioDispatcher = Dispatchers.Unconfined, cpuDispatcher = Dispatchers.Unconfined)
        }
        every { repo.observeMetadata(any()) } answers {
            flowOf(Conversation(id = firstArg(), title = "Chat", providerID = "p", providerKind = ProviderKind.OpenAI, modelID = "gpt", messages = emptyList()))
        }
    }

    private val activeConversationId = MutableStateFlow<String?>(null)

    /** Replaces the tail-window observation with a hot flow that counts subscribers: loader observation alive = 1, stopped = 0. */
    private fun liveLatestWindow(): MutableStateFlow<List<MessageEntity>> {
        val live = MutableStateFlow(rows)
        every { dao.observeLatestMessageWindow(any(), any(), any()) } answers {
            val limit = thirdArg<Int>()
            live.map { it.takeLast(limit) }
        }
        return live
    }

    /** WhileSubscribed: the upstream starts only once the render flow and all derived flows are subscribed. */
    private fun TestScope.subscribedCoordinator(): ChatMessageWindowCoordinator {
        val window = ChatMessageWindowCoordinator(
            scope = backgroundScope,
            conversationRepository = repository,
            activeConversationId = activeConversationId,
        )
        listOf(window.conversation, window.hasMoreAbove, window.isLoadingAbove, window.hasMoreBelow, window.isLoadingBelow, window.isInitialLoading)
            .forEach { flow -> backgroundScope.launch { flow.collect {} } }
        return window
    }

    private fun ChatMessageWindowCoordinator.messageTexts() =
        conversation.value.conversation?.messages.orEmpty().map { it.text }

    @Test
    fun `no active conversation renders empty state`() = runTest(UnconfinedTestDispatcher()) {
        val window = subscribedCoordinator()
        advanceUntilIdle()

        assertNull(window.conversation.value.conversation)
        assertFalse(window.hasMoreAbove.value)
        assertFalse(window.hasMoreBelow.value)
        assertFalse(window.isInitialLoading.value)
    }

    @Test
    fun `active conversation merges metadata with latest window and pages above`() = runTest(UnconfinedTestDispatcher()) {
        seed()
        val window = subscribedCoordinator()
        activeConversationId.value = convId
        advanceUntilIdle()

        assertEquals("Chat", window.conversation.value.conversation?.title)
        assertEquals(listOf("m3", "m4"), window.messageTexts())
        assertTrue(window.hasMoreAbove.value)
        assertFalse(window.hasMoreBelow.value)
        assertFalse(window.isInitialLoading.value)
        assertFalse(window.isLoadingAbove.value)

        window.loadMoreAbove()
        advanceUntilIdle()
        assertEquals(listOf("m1", "m2", "m3", "m4"), window.messageTexts())
        assertTrue(window.hasMoreAbove.value)

        window.loadMoreAbove()
        advanceUntilIdle()
        assertEquals(listOf("m0", "m1", "m2", "m3", "m4"), window.messageTexts())
        assertFalse(window.hasMoreAbove.value)
    }

    @Test
    fun `focus on a local message opens anchor window that pages below`() = runTest(UnconfinedTestDispatcher()) {
        seed()
        val window = subscribedCoordinator()
        activeConversationId.value = convId
        advanceUntilIdle()

        window.loadFocusMessageWindow(msgId(1))
        advanceUntilIdle()
        assertEquals(listOf("m0", "m1"), window.messageTexts())
        assertTrue(window.hasMoreBelow.value)
        assertFalse(window.hasMoreAbove.value)
        coVerify(exactly = 0) { repository.hydrateRemoteMessageWindowAround(any(), any(), any()) }

        window.loadMoreBelow()
        advanceUntilIdle()
        assertEquals(listOf("m0", "m1", "m2", "m3"), window.messageTexts())
        assertTrue(window.hasMoreBelow.value)
        assertFalse(window.isLoadingBelow.value)
    }

    @Test
    fun `focus without active conversation does nothing`() = runTest(UnconfinedTestDispatcher()) {
        val window = subscribedCoordinator()
        window.loadFocusMessageWindow(msgId(1))
        advanceUntilIdle()

        coVerify(exactly = 0) { repository.hydrateRemoteMessageWindowAround(any(), any(), any()) }
        assertNull(window.conversation.value.conversation)
    }

    @Test
    fun `deactivating conversation stops the loader`() = runTest(UnconfinedTestDispatcher()) {
        seed()
        val live = liveLatestWindow()
        val window = subscribedCoordinator()
        activeConversationId.value = convId
        advanceUntilIdle()
        assertTrue(window.hasMoreAbove.value)
        assertEquals(1, live.subscriptionCount.value)

        activeConversationId.value = null
        advanceUntilIdle()
        assertNull(window.conversation.value.conversation)
        assertTrue(window.conversation.value.windowState.messages.isEmpty())
        assertFalse(window.hasMoreAbove.value)
        // The render flow switching to empty does not mean the loader stopped: its DAO observation must be cancelled.
        assertEquals("The loader is still observing the DAO", 0, live.subscriptionCount.value)
    }

    @Test
    fun bind_starts_loader_for_new_conversation() = runTest(UnconfinedTestDispatcher()) {
        seed()
        val live = liveLatestWindow()
        val window = subscribedCoordinator()
        advanceUntilIdle()
        assertEquals(0, live.subscriptionCount.value)

        // First send creates the conversation: activeConversationId has not switched yet, so the host binds first.
        window.bind(convId)
        advanceUntilIdle()

        verify(exactly = 1) { dao.observeLatestMessageWindow(any(), convId, 2) }
        assertEquals(1, live.subscriptionCount.value)

        // Then activeConversationId switches to the same conversation: a repeated bind is a no-op and the loaded window is rendered directly.
        activeConversationId.value = convId
        advanceUntilIdle()
        verify(exactly = 1) { dao.observeLatestMessageWindow(any(), convId, 2) }
        assertEquals(listOf("m3", "m4"), window.messageTexts())
    }

    @Test
    fun stop_halts_loader() = runTest(UnconfinedTestDispatcher()) {
        seed()
        val live = liveLatestWindow()
        val window = subscribedCoordinator()
        activeConversationId.value = convId
        advanceUntilIdle()
        assertEquals(listOf("m3", "m4"), window.messageTexts())
        assertEquals(1, live.subscriptionCount.value)

        // Host onCleared.
        window.stop()
        advanceUntilIdle()

        assertEquals("The loader is still observing the DAO", 0, live.subscriptionCount.value)
        assertTrue(window.messageTexts().isEmpty())
        assertFalse(window.hasMoreAbove.value)
    }
}
