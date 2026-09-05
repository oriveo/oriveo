package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.chat.MessageWindowLoader
import ai.oriveo.community.core.model.ChatMessage
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.flowOf


class MessageWindowFakeStore {
    private val messages = mutableMapOf<String, List<MessageEntity>>()

    fun put(conversationId: String, msgs: List<ChatMessage>) {
        messages[conversationId] = msgs.mapIndexed { i, m -> m.toEntity("guest", conversationId, i) }
    }

    fun clear() {
        messages.clear()
    }

    val fakeDao: MessageDao = mockk<MessageDao>(relaxed = true).also { dao ->
        every { dao.observeLatestMessageWindow(any(), any(), any()) } answers {
            val convId = secondArg<String>()
            val limit = thirdArg<Int>()
            flowOf(messages[convId].orEmpty().takeLast(limit))
        }
        coEvery { dao.existsBefore(any(), any(), any(), any()) } answers {
            val convId = secondArg<String>()
            val so = thirdArg<Int>()
            val id = arg<String>(3)
            messages[convId].orEmpty().any {
                it.sortOrder < so || (it.sortOrder == so && it.id < id)
            }
        }
        coEvery { dao.fetchMessagesBefore(any(), any(), any(), any(), any()) } answers {
            val convId = secondArg<String>()
            val so = thirdArg<Int>()
            val id = arg<String>(3)
            val limit = arg<Int>(4)
            messages[convId].orEmpty()
                .filter { it.sortOrder < so || (it.sortOrder == so && it.id < id) }
                .takeLast(limit)
        }
    }
}


fun ConversationRepository.stubMessageWindowLoaderDefaults(
    store: MessageWindowFakeStore,
    
    
    
    dispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
) {
    every { createMessageWindowLoader() } answers {
        MessageWindowLoader(
            messageDao = store.fakeDao,
            ioDispatcher = dispatcher,
            cpuDispatcher = dispatcher,
        )
    }
    every { observeMetadata(any()) } returns flowOf(null)
    coEvery { getWithLatestMessageWindow(any(), any()) } returns null
}
