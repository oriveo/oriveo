package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * Pins down the deduplication surface of [ConversationRepository.observeMetadata].
 *
 * The only subscriber is the chat view model's conversation flow, and one emission recomposes the
 * whole chat screen — which invalidates the message list and therefore recomposes **every visible
 * cell along with its markdown subtree**. Each field in the fingerprint is thus a licence to push
 * the entire screen into the recomposition queue: the draft debounce writes to the database several
 * times a second, so including `draftText`, `previewText` or `updatedAt` would wire typing straight
 * back to a full-screen recomposition.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ConversationMetadataFlowTest {

    private val conversationDao = mockk<ConversationDao>()
    private val messageDao = mockk<MessageDao>(relaxed = true)
    private val testAccountId = LOCAL_PARTITION_ID

    private lateinit var repository: ConversationRepository

    @Before
    fun setUp() {
        repository = ConversationRepository(conversationDao, messageDao)
    }

    @Test
    fun `draft debounce churn never re-emits but blank to non-blank still does`() = runTest {
        val base = conversationEntity()
        every { conversationDao.observeById(testAccountId, "CONV-1") } returns flowOf(
            base,
            base.copy(draftText = "h", previewText = "h", updatedAt = base.updatedAt + 1),
            base.copy(draftText = "he", previewText = "he", updatedAt = base.updatedAt + 2),
            base.copy(draftText = "hel", previewText = "hel", updatedAt = base.updatedAt + 3),
            base.copy(draftText = "", updatedAt = base.updatedAt + 4),
            base.copy(draftText = "", title = "Renamed", updatedAt = base.updatedAt + 5),
        )

        val emitted = repository.observeMetadata("CONV-1").take(4).toList()

        assertEquals("", emitted[0]?.draftText)
        assertEquals("blank to non-blank is what resolveChatLoadState reads, so it has to pass", "h", emitted[1]?.draftText)
        // The key assertion: if per-keystroke draft writes could still punch through, this would be
        // "he" rather than the cleared "".
        assertEquals("per-keystroke draft writes must not punch through the chat metadata flow", "", emitted[2]?.draftText)
        assertEquals("a real metadata change still passes", "Renamed", emitted[3]?.title)
    }

    @Test
    fun `fields the chat screen actually renders still re-emit`() = runTest {
        val base = conversationEntity()
        every { conversationDao.observeById(testAccountId, "CONV-1") } returns flowOf(
            base,
            base.copy(estimatedCost = 1.25),
            base.copy(estimatedCost = 1.25, modelID = "gpt-5"),
            base.copy(estimatedCost = 1.25, modelID = "gpt-5", useMemory = false),
        )

        val emitted = repository.observeMetadata("CONV-1").take(4).toList()

        assertEquals(1.25, emitted[1]?.estimatedCost ?: 0.0, 0.0001)
        assertEquals("gpt-5", emitted[2]?.modelID)
        assertEquals(false, emitted[3]?.useMemory)
    }

    private fun conversationEntity() = ConversationEntity(
        id = "CONV-1",
        title = "Metadata flow test",
        hasCustomTitle = false,
        providerID = "PROVIDER-1",
        providerKind = ProviderKind.OpenAI.name,
        modelID = "gpt-4o",
        previewText = "Hello",
        estimatedCost = 0.0,
        isDraft = false,
        draftText = "",
        createdAt = 1700000000000L,
        updatedAt = 1700000000000L,
        accountId = testAccountId,
    )
}
