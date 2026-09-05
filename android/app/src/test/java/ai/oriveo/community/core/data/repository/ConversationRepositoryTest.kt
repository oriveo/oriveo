package ai.oriveo.community.core.data.repository


import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.MessageContinuationDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.ConversationWithCount
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.entity.MonthlyCostRow
import ai.oriveo.community.core.data.entity.MonthlyProviderCostRow
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.usage.CostSummarySource
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.slot
import io.mockk.verify
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test


@OptIn(ExperimentalCoroutinesApi::class)
class ConversationRepositoryTest {

    private val conversationDao = mockk<ConversationDao>()
    private val messageDao = mockk<MessageDao>()

    private lateinit var repository: ConversationRepository

    private val testAccountId = LOCAL_PARTITION_ID

    @Before
    fun setUp() {
        repository = ConversationRepository(conversationDao, messageDao)
    }

    @Test
    fun `edit and regenerate deletion chunks more than one thousand continuation ids`() = runTest {
        val localConversationDao = mockk<ConversationDao>(relaxed = true)
        val localMessageDao = mockk<MessageDao>(relaxed = true)
        val continuationDao = mockk<MessageContinuationDao>(relaxed = true)
        val local = ConversationRepository(
            localConversationDao, localMessageDao,
            continuationDao = continuationDao,
        )
        val anchor = makeMessageEntity("anchor", sortOrder = 0)
        val deleted = (1..1_205).map { index -> makeMessageEntity("deleted-$index", sortOrder = index) }
        coEvery { localConversationDao.getById(testAccountId, "CONV-1") } returns null
        coEvery { localMessageDao.lastDelivered(testAccountId, "CONV-1") } returns null
        coEvery { localMessageDao.lastDeliveredUser(testAccountId, "CONV-1") } returns null
        coEvery { localMessageDao.getById(testAccountId, "anchor") } returns anchor
        coEvery { localMessageDao.getByConversation(testAccountId, "CONV-1") } returns listOf(anchor) + deleted

        local.deleteMessagesAfter("CONV-1", "anchor")

        val chunks = mutableListOf<List<String>>()
        coVerify(exactly = 3) { continuationDao.deleteMessages(testAccountId, capture(chunks)) }
        assertEquals(listOf(500, 500, 205), chunks.map { it.size })
        assertEquals(deleted.map { it.id }, chunks.flatten())

        io.mockk.clearMocks(continuationDao, answers = false, recordedCalls = true)
        coEvery { localMessageDao.getById(testAccountId, "anchor") } returns anchor
        coEvery { localMessageDao.getByConversation(testAccountId, "CONV-1") } returns listOf(anchor) + deleted
        local.deleteMessagesStartingAt("CONV-1", "anchor")
        val startingChunks = mutableListOf<List<String>>()
        coVerify(exactly = 3) { continuationDao.deleteMessages(testAccountId, capture(startingChunks)) }
        assertEquals(listOf(500, 500, 206), startingChunks.map { it.size })
        assertEquals(listOf(anchor.id) + deleted.map { it.id }, startingChunks.flatten())
    }

    @Test
    fun `single and batch conversation deletion remove independent continuation rows`() = runTest {
        val localConversationDao = mockk<ConversationDao>(relaxed = true)
        val localMessageDao = mockk<MessageDao>(relaxed = true)
        val continuationDao = mockk<MessageContinuationDao>(relaxed = true)
        val local = ConversationRepository(
            localConversationDao, localMessageDao,
            continuationDao = continuationDao,
        )
        coEvery { localConversationDao.getById(testAccountId, any()) } returns makeConversationEntity()
        coEvery { localMessageDao.getByConversation(testAccountId, any()) } returns emptyList()

        local.delete("CONV-1")
        local.deleteMultiple(listOf("CONV-2", "CONV-3"))

        coVerify(exactly = 1) { continuationDao.deleteForConversation(testAccountId, "CONV-1") }
        coVerify(exactly = 1) { continuationDao.deleteForConversation(testAccountId, "CONV-2") }
        coVerify(exactly = 1) { continuationDao.deleteForConversation(testAccountId, "CONV-3") }
    }

    

    private fun makeConversationEntity(
        id: String = "CONV-1",
        estimatedCost: Double = 0.0,
    ) = ConversationEntity(
        id = id,
        title = "Test Chat",
        hasCustomTitle = false,
        providerID = "PROVIDER-1",
        providerKind = ProviderKind.OpenAI.name,
        modelID = "gpt-4o",
        previewText = "Hello",
        estimatedCost = estimatedCost,
        isDraft = false,
        draftText = "",
        createdAt = 1700000000000L,
        updatedAt = 1700000000000L,
        accountId = testAccountId,
    )

    private fun makeMessageEntity(
        id: String,
        conversationId: String = "CONV-1",
        state: String = ChatMessageState.Delivered.name,
        estimatedCost: Double = 0.0,
        sortOrder: Int = 0,
    ) = MessageEntity(
        id = id,
        conversationId = conversationId,
        role = "User",
        text = "Hello",
        providerKind = "OpenAI",
        providerName = "OpenAI",
        modelName = "GPT-4o",
        estimatedCost = estimatedCost,
        state = state,
        errorTitle = null,
        errorDetail = null,
        attachmentsJson = null,
        createdAt = 1700000000000L,
        sortOrder = sortOrder,
    )

    

    @Test
    fun `refreshCost recalculates correctly after message deletion`() = runTest {
        // Setup: conversation with 3 messages, one is about to be "deleted"
        val conv = makeConversationEntity(estimatedCost = 0.30)
        val msg1 = makeMessageEntity("MSG-1", estimatedCost = 0.10, sortOrder = 0)
        val msg2 = makeMessageEntity("MSG-2", estimatedCost = 0.10, sortOrder = 1)
        // msg3 has been deleted — only msg1 and msg2 remain

        coEvery { messageDao.getByConversation(testAccountId, "CONV-1") } returns listOf(msg1, msg2)
        
        coEvery { messageDao.sumDeliveredCost(testAccountId, "CONV-1", CostFormatter.COST_EPSILON) } returns 0.20
        coEvery { conversationDao.getById(testAccountId, "CONV-1") } returns conv
        val updatedEntitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedEntitySlot)) } just runs

        repository.refreshCost("CONV-1")

        assertTrue(updatedEntitySlot.isCaptured)
        assertEquals(
            "Cost should be sum of remaining messages (0.10 + 0.10 = 0.20)",
            0.20,
            updatedEntitySlot.captured.estimatedCost,
            0.00001,
        )
    }

    @Test
    fun `refreshCost drops to zero when all messages deleted`() = runTest {
        val conv = makeConversationEntity(estimatedCost = 0.50)

        coEvery { messageDao.getByConversation(testAccountId, "CONV-1") } returns emptyList()
        coEvery { messageDao.sumDeliveredCost(testAccountId, "CONV-1", CostFormatter.COST_EPSILON) } returns 0.0
        coEvery { conversationDao.getById(testAccountId, "CONV-1") } returns conv
        val updatedEntitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedEntitySlot)) } just runs

        repository.refreshCost("CONV-1")

        assertTrue(updatedEntitySlot.isCaptured)
        assertEquals(
            "Cost should be 0 when no messages remain",
            0.0,
            updatedEntitySlot.captured.estimatedCost,
            0.00001,
        )
    }

    @Test
    fun `refreshCost ignores non-delivered messages`() = runTest {
        val conv = makeConversationEntity(estimatedCost = 0.30)
        val delivered = makeMessageEntity("MSG-1", estimatedCost = 0.10, sortOrder = 0)
        val generating = makeMessageEntity(
            "MSG-2",
            estimatedCost = 0.10,
            sortOrder = 1,
            state = ChatMessageState.Generating.name,
        )
        val failed = makeMessageEntity(
            "MSG-3",
            estimatedCost = 0.10,
            sortOrder = 2,
            state = ChatMessageState.Failed.name,
        )

        coEvery { messageDao.getByConversation(testAccountId, "CONV-1") } returns listOf(delivered, generating, failed)
        coEvery { messageDao.sumDeliveredCost(testAccountId, "CONV-1", CostFormatter.COST_EPSILON) } returns 0.10
        coEvery { conversationDao.getById(testAccountId, "CONV-1") } returns conv
        val updatedEntitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedEntitySlot)) } just runs

        repository.refreshCost("CONV-1")

        assertTrue(updatedEntitySlot.isCaptured)
        assertEquals(
            "Only Delivered messages should be counted",
            0.10,
            updatedEntitySlot.captured.estimatedCost,
            0.00001,
        )
    }

    @Test
    fun `refreshCost ignores messages below epsilon`() = runTest {
        val conv = makeConversationEntity(estimatedCost = 0.10)
        val normal = makeMessageEntity("MSG-1", estimatedCost = 0.05, sortOrder = 0)
        val belowEpsilon = makeMessageEntity(
            "MSG-2",
            estimatedCost = CostFormatter.COST_EPSILON * 0.5,
            sortOrder = 1,
        )

        coEvery { messageDao.getByConversation(testAccountId, "CONV-1") } returns listOf(normal, belowEpsilon)
        coEvery { messageDao.sumDeliveredCost(testAccountId, "CONV-1", CostFormatter.COST_EPSILON) } returns 0.05
        coEvery { conversationDao.getById(testAccountId, "CONV-1") } returns conv
        val updatedEntitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedEntitySlot)) } just runs

        repository.refreshCost("CONV-1")

        assertTrue(updatedEntitySlot.isCaptured)
        assertEquals(
            "Messages below epsilon should be excluded from cost",
            0.05,
            updatedEntitySlot.captured.estimatedCost,
            0.00001,
        )
    }

    

    @Test
    fun `refreshCost after resend reflects new message cost`() = runTest {
        // Scenario: user edited and resent — old messages deleted, new message added.
        // Before: msg1 ($0.10) + msg2 ($0.20) = $0.30
        // After resend: msg1 ($0.10) + msg3 ($0.15) = $0.25
        val conv = makeConversationEntity(estimatedCost = 0.30)
        val msg1 = makeMessageEntity("MSG-1", estimatedCost = 0.10, sortOrder = 0)
        val msg3 = makeMessageEntity("MSG-3", estimatedCost = 0.15, sortOrder = 1)

        coEvery { messageDao.getByConversation(testAccountId, "CONV-1") } returns listOf(msg1, msg3)
        coEvery { messageDao.sumDeliveredCost(testAccountId, "CONV-1", CostFormatter.COST_EPSILON) } returns 0.25
        coEvery { conversationDao.getById(testAccountId, "CONV-1") } returns conv
        val updatedEntitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedEntitySlot)) } just runs

        repository.refreshCost("CONV-1")

        assertTrue(updatedEntitySlot.isCaptured)
        assertEquals(
            "Cost after resend should be sum of current messages (0.10 + 0.15 = 0.25)",
            0.25,
            updatedEntitySlot.captured.estimatedCost,
            0.00001,
        )
    }

    @Test
    fun `refreshCost with no conversation does not crash`() = runTest {
        coEvery { messageDao.getByConversation(testAccountId, "CONV-MISSING") } returns emptyList()
        coEvery { messageDao.sumDeliveredCost(testAccountId, "CONV-MISSING", CostFormatter.COST_EPSILON) } returns 0.0
        coEvery { conversationDao.getById(testAccountId, "CONV-MISSING") } returns null

        // Should not throw
        repository.refreshCost("CONV-MISSING")

        // Verify update was never called since conversation doesn't exist
        coVerify(exactly = 0) { conversationDao.update(any()) }
    }

    @Test
    fun `updateUseMemory updates room and sync adapter`() = runTest {
        coEvery { conversationDao.updateUseMemory(testAccountId, "CONV-1", false) } returns Unit

        repository.updateUseMemory("CONV-1", false)

        coVerify { conversationDao.updateUseMemory(testAccountId, "CONV-1", false) }
    }

    @Test
    fun `updateDraft clearing existing conversation restores last delivered preview`() = runTest {
        val entity = makeConversationEntity().copy(
            previewText = "stale draft preview",
            draftText = "stale draft preview",
        )
        val lastDelivered = makeMessageEntity(
            id = "MSG-2",
            state = ChatMessageState.Delivered.name,
            sortOrder = 1,
        ).copy(
            role = "Assistant",
            text = "Last delivered reply",
        )

        coEvery { conversationDao.getById(testAccountId, "CONV-1") } returns entity
        coEvery { messageDao.getByConversation(testAccountId, "CONV-1") } returns listOf(lastDelivered)
        val updatedEntitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedEntitySlot)) } just runs

        repository.updateDraft("CONV-1", "")

        assertTrue(updatedEntitySlot.isCaptured)
        assertEquals("", updatedEntitySlot.captured.draftText)
        assertEquals("Last delivered reply", updatedEntitySlot.captured.previewText)
    }

    @Test
    fun `updateDraft clearing empty draft conversation removes stale preview`() = runTest {
        val entity = makeConversationEntity().copy(
            previewText = "stale draft preview",
            draftText = "stale draft preview",
            isDraft = true,
        )

        coEvery { conversationDao.getById(testAccountId, "CONV-1") } returns entity
        coEvery { messageDao.getByConversation(testAccountId, "CONV-1") } returns emptyList()
        val updatedEntitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedEntitySlot)) } just runs

        repository.updateDraft("CONV-1", "")

        assertTrue(updatedEntitySlot.isCaptured)
        assertEquals("", updatedEntitySlot.captured.draftText)
        assertEquals("", updatedEntitySlot.captured.previewText)
    }

    @Test
    fun `observeMonthlyCostSummary maps sorted provider aggregates from DAO`() = runTest {
        every {
            messageDao.observeMonthlyCostByProviderKind(
                accountId = testAccountId,
                minimumCostExclusive = CostFormatter.COST_EPSILON,
                windowStartMillis = any(),
                windowEndMillis = any(),
            )
        } returns flowOf(
            
            listOf(
                MonthlyCostRow(providerKind = "Anthropic", providerID = "anthropic-1", totalCost = 1.4),
                MonthlyCostRow(providerKind = "OpenAI", providerID = "openai-1", totalCost = 2.1),
                MonthlyCostRow(providerKind = "Relay", providerID = "relay-a", totalCost = 0.4),
                MonthlyCostRow(providerKind = "Relay", providerID = "relay-b", totalCost = 0.6),
            ),
        )

        val summary = repository.observeMonthlyCostSummary(visibleProviderLimit = 2).first()

        
        assertEquals(4.5, summary.totalCost, 0.00001)
        assertEquals(listOf("openai-1", "anthropic-1"), summary.providers.map { it.providerID })
        assertEquals(2, summary.hiddenProviderCount)
        assertEquals(CostSummarySource.LocalDevice, summary.source)
    }

    @Test
    fun `observeUngroupedHomeConversations merges recent and earlier rows`() = runTest {
        every {
            conversationDao.observeUngroupedRecentWithCount(testAccountId, 1_000L)
        } returns flowOf(
            listOf(
                ConversationWithCount(
                    entity = makeConversationEntity(id = "RECENT"),
                    messageCount = 1,
                ),
            ),
        )
        every {
            conversationDao.observeUngroupedEarlierWithCount(testAccountId, 1_000L, 10)
        } returns flowOf(
            listOf(
                ConversationWithCount(
                    entity = makeConversationEntity(id = "EARLIER"),
                    messageCount = 2,
                ),
            ),
        )

        val conversations = repository.observeUngroupedHomeConversations(
            recentStartMillis = 1_000L,
            earlierLimit = 10,
        ).first()

        assertEquals(listOf("RECENT", "EARLIER"), conversations.map { it.id })
        assertEquals(listOf(1, 2), conversations.map { it.messageCount })
    }

    @Test
    fun `observeUngroupedEarlierCount forwards DAO count`() = runTest {
        every { conversationDao.observeUngroupedEarlierCount(testAccountId, 1_000L) } returns flowOf(14)

        val count = repository.observeUngroupedEarlierCount(1_000L).first()

        assertEquals(14, count)
    }

    @Test
    fun `observeMonthlyCostByConversationProvider returns provider cost map`() = runTest {
        every {
            messageDao.observeMonthlyCostByConversationProvider(
                accountId = testAccountId,
                minimumCostExclusive = CostFormatter.COST_EPSILON,
                windowStartMillis = any(),
                windowEndMillis = any(),
            )
        } returns flowOf(
            listOf(
                MonthlyProviderCostRow(providerId = "provider-a", totalCost = 1.25),
                MonthlyProviderCostRow(providerId = "provider-b", totalCost = 0.75),
            ),
        )

        val costs = repository.observeMonthlyCostByConversationProvider().first()

        assertEquals(2, costs.size)
        assertEquals(1.25, costs["provider-a"] ?: 0.0, 0.00001)
        assertEquals(0.75, costs["provider-b"] ?: 0.0, 0.00001)
    }

    // ── Folder Operations ─────────────────────────────────────

    @Test
    fun `moveToFolder updates conversation folderID`() = runTest {
        coEvery { conversationDao.updateFolderID(testAccountId, "c1", "f1") } returns Unit

        repository.moveToFolder("c1", "f1")

        coVerify { conversationDao.updateFolderID(testAccountId, "c1", "f1") }
    }

    @Test
    fun `moveToFolder with null removes from folder`() = runTest {
        coEvery { conversationDao.updateFolderID(testAccountId, "c1", null) } returns Unit

        repository.moveToFolder("c1", null)

        coVerify { conversationDao.updateFolderID(testAccountId, "c1", null) }
    }

    @Test
    fun `batchMoveToFolder moves multiple conversations`() = runTest {
        coEvery { conversationDao.batchUpdateFolderID(testAccountId, any(), any()) } returns Unit

        repository.batchMoveToFolder(listOf("c1", "c2", "c3"), "f1")

        coVerify {
            conversationDao.batchUpdateFolderID(testAccountId, listOf("c1", "c2", "c3"), "f1")
        }
    }

    @Test
    fun `batchMoveToFolder deduplicates conversation IDs`() = runTest {
        coEvery { conversationDao.batchUpdateFolderID(testAccountId, any(), any()) } returns Unit

        repository.batchMoveToFolder(listOf("c1", "c1", "c2"), "f1")

        coVerify {
            conversationDao.batchUpdateFolderID(testAccountId, listOf("c1", "c2"), "f1")
        }
    }

    

    
    @Test
    fun `TC-4-1-2 cross-folder move calls updateFolderID with new folder`() = runTest {
        coEvery { conversationDao.updateFolderID(testAccountId, any(), any()) } returns Unit

        repository.moveToFolder("c1", "folder-b")

        coVerify { conversationDao.updateFolderID(testAccountId, any(), "folder-b") }
    }

    
    @Test
    fun `TC-4-1-3 move out of folder passes null to updateFolderID`() = runTest {
        coEvery { conversationDao.updateFolderID(testAccountId, "c1", null) } returns Unit

        repository.moveToFolder("c1", null)

        coVerify { conversationDao.updateFolderID(testAccountId, "c1", null) }
    }

    
    @Test
    fun `TC-4-1-4 moveToFolder does not update updatedAt`() = runTest {
        coEvery { conversationDao.updateFolderID(testAccountId, any(), any()) } returns Unit

        repository.moveToFolder("c1", "f1")

        coVerify(exactly = 1) { conversationDao.updateFolderID(testAccountId, "c1", "f1") }
    }

    
    @Test
    fun `TC-4-1-6 moveToFolder with non-existent conversation does not crash`() = runTest {
        coEvery { conversationDao.updateFolderID(testAccountId, any(), any()) } returns Unit

        repository.moveToFolder("non-existent-id", "f1")

        
        coVerify { conversationDao.updateFolderID(testAccountId, any(), "f1") }
    }

    
    @Test
    fun `TC-4-1-7 moveToFolder overwrites previous folderID (single ownership)`() = runTest {
        coEvery { conversationDao.updateFolderID(testAccountId, any(), any()) } returns Unit

        repository.moveToFolder("c1", "folder-a")
        repository.moveToFolder("c1", "folder-b")

        
        coVerify { conversationDao.updateFolderID(testAccountId, any(), "folder-a") }
        coVerify { conversationDao.updateFolderID(testAccountId, any(), "folder-b") }
    }

    
    @Test
    fun `TC-5-1-2 batchMoveToFolder with null removes all from folder`() = runTest {
        coEvery { conversationDao.batchClearFolderID(testAccountId, any()) } returns Unit

        repository.batchMoveToFolder(listOf("c1", "c2", "c3"), null)

        coVerify { conversationDao.batchClearFolderID(testAccountId, listOf("c1", "c2", "c3")) }
    }

    
    @Test
    fun `TC-5-1-3 batchMoveToFolder mixed state all get new folderID`() = runTest {
        coEvery { conversationDao.batchUpdateFolderID(testAccountId, any(), any()) } returns Unit

        repository.batchMoveToFolder(listOf("c1", "c2", "c3"), "folder-b")

        coVerify { conversationDao.batchUpdateFolderID(testAccountId, listOf("c1", "c2", "c3"), "folder-b") }
    }

    
    @Test
    fun `TC-5-1-4 batchMoveToFolder empty selection does nothing`() = runTest {
        repository.batchMoveToFolder(emptyList(), "f1")

        coVerify(exactly = 0) { conversationDao.updateFolderID(testAccountId, any(), any()) }
    }

    
    @Test
    fun `TC-5-1-5 batchMoveToFolder with invalid IDs does not crash`() = runTest {
        coEvery { conversationDao.batchUpdateFolderID(testAccountId, any(), any()) } returns Unit

        repository.batchMoveToFolder(listOf("valid-1", "non-existent-uuid"), "f1")

        coVerify {
            conversationDao.batchUpdateFolderID(testAccountId, listOf("valid-1", "non-existent-uuid"), "f1")
        }
    }

    
    @Test
    fun `TC-5-1-6 batchMoveToFolder syncs each conversation`() = runTest {
        coEvery { conversationDao.batchUpdateFolderID(testAccountId, any(), any()) } returns Unit

        repository.batchMoveToFolder(listOf("c1", "c2", "c3"), "f1")

    }

    

    
    @Test
    fun `TC-8-1-1 search includes conversations in folders`() = runTest {
        val entityInFolder = makeConversationEntity(id = "CONV-FOLDER-1").copy(
            folderID = "FOLDER-1",
            title = "AI Discussion"
        )
        every { conversationDao.searchWithCount("AI", testAccountId) } returns flowOf(
            listOf(ConversationWithCount(entity = entityInFolder, messageCount = 0))
        )

        val results = repository.search("AI").first()

        assertEquals(1, results.size)
        assertEquals("FOLDER-1", results[0].folderID)
        assertEquals("AI Discussion", results[0].title)
    }

    
    @Test
    fun `TC-8-1-2 search result has folderID for folder conversations`() = runTest {
        val entityInFolder = makeConversationEntity(id = "CONV-FOLDER-2").copy(
            folderID = "FOLDER-2",
            title = "Budget Planning"
        )
        every { conversationDao.searchWithCount("Budget", testAccountId) } returns flowOf(
            listOf(ConversationWithCount(entity = entityInFolder, messageCount = 0))
        )

        val results = repository.search("Budget").first()

        assertTrue(results.isNotEmpty())
        assertEquals("FOLDER-2", results[0].folderID)
    }

    
    @Test
    fun `TC-8-1-3 search result has null folderID for unfiled conversations`() = runTest {
        val entity = makeConversationEntity(id = "CONV-NO-FOLDER")
        every { conversationDao.searchWithCount("Test", testAccountId) } returns flowOf(
            listOf(ConversationWithCount(entity = entity, messageCount = 0))
        )

        val results = repository.search("Test").first()

        assertEquals(1, results.size)
        assertEquals(null, results[0].folderID)
    }

    

    // TC-10.1.1: createDraft with folderID → result has folderID set, isDraft=true
    @Test
    fun `TC-10-1-1 createDraft with folderID sets folderID and isDraft`() = runTest {
        coEvery { conversationDao.upsert(any()) } returns Unit

        val result = repository.createDraft(
            providerID = "PROVIDER-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
            folderID = "folder-1",
        )

        assertTrue("isDraft should be true", result.isDraft)
        assertEquals("folder-1", result.folderID)
    }

    // TC-10.1.2: createDraft without folderID → result has folderID=null
    @Test
    fun `TC-10-1-2 createDraft without folderID has null folderID`() = runTest {
        coEvery { conversationDao.upsert(any()) } returns Unit

        val result = repository.createDraft(
            providerID = "PROVIDER-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
        )

        assertTrue("isDraft should be true", result.isDraft)
        assertEquals(null, result.folderID)
    }

    
    @Test
    fun `TC-10-1-3 createDraft with folderID passes folderID to DAO upsert`() = runTest {
        val entitySlot = slot<ConversationEntity>()
        coEvery { conversationDao.upsert(capture(entitySlot)) } returns Unit

        repository.createDraft(
            providerID = "PROVIDER-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
            folderID = "folder-1",
        )

        assertTrue(entitySlot.isCaptured)
        assertEquals("folder-1", entitySlot.captured.folderID)
        assertTrue("Entity isDraft should be true", entitySlot.captured.isDraft)
    }

    
    
    
    
    
    @Test
    fun `TC-10-1-4 createDraft folderID retained through addMessage first-message path`() = runTest {
        val convSlot = slot<ConversationEntity>()
        coEvery { conversationDao.upsert(capture(convSlot)) } returns Unit

        val draft = repository.createDraft(
            providerID = "PROVIDER-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
            folderID = "folder-1",
        )
        assertEquals("folder-1", draft.folderID)
        val draftEntity = convSlot.captured
        val convId = draftEntity.id

        
        coEvery { messageDao.maxSortOrder(testAccountId, convId) } returns null
        coEvery { messageDao.upsert(any()) } returns Unit
        coEvery { conversationDao.getById(testAccountId, convId) } returns draftEntity
        val deliveredMessage = ChatMessage(
            id = "MSG-USER-1",
            role = ChatRole.User,
            text = "Hello from folder draft",
            providerID = "PROVIDER-1",
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelID = "gpt-4o",
            modelName = "GPT-4o",
            state = ChatMessageState.Delivered,
            createdAt = 1700000000000L,
        )
        val msgEntity = makeMessageEntity("MSG-USER-1", conversationId = convId, sortOrder = 0)
        
        coEvery { messageDao.lastDelivered(testAccountId, convId) } returns msgEntity
        coEvery { messageDao.lastDeliveredUser(testAccountId, convId) } returns msgEntity

        val updatedSlot = slot<ConversationEntity>()
        coEvery { conversationDao.update(capture(updatedSlot)) } just runs

        repository.addMessage(convId, deliveredMessage)

        
        
        assertTrue("conversationDao.update should be captured", updatedSlot.isCaptured)
        assertEquals(
            "folderID must survive refreshConversationMetadata",
            "folder-1",
            updatedSlot.captured.folderID,
        )
        assertEquals("isDraft should transition to false", false, updatedSlot.captured.isDraft)

        
    }

    
    
    
    @Test
    fun `TC-BugB updateMessage assistant delivered syncs whole round via didCompleteRound`() = runTest {
        val convId = "CONV-1"
        val userEntity = makeMessageEntity("MSG-USER-1", conversationId = convId, sortOrder = 0)
        val assistantEntity = makeMessageEntity("MSG-AI-1", conversationId = convId, sortOrder = 1)
            .copy(role = "Assistant", estimatedCost = 0.05)
        val convEntity = makeConversationEntity(convId).copy(folderID = "folder-1")

        coEvery { messageDao.getById(testAccountId, "MSG-AI-1") } returns assistantEntity
        coEvery { messageDao.upsert(any()) } returns Unit
        coEvery { conversationDao.getById(testAccountId, convId) } returns convEntity
        
        coEvery { messageDao.lastDelivered(testAccountId, convId) } returns assistantEntity
        coEvery { messageDao.lastDeliveredUser(testAccountId, convId) } returns userEntity
        coEvery { messageDao.lastDeliveredUserBefore(testAccountId, convId, 1) } returns userEntity
        coEvery { messageDao.countDeliveredByConversation(testAccountId, convId) } returns 2
        coEvery { messageDao.sumDeliveredCost(testAccountId, convId, CostFormatter.COST_EPSILON) } returns 0.05
        coEvery { conversationDao.update(any()) } just runs

        val deliveredAssistant = ChatMessage(
            id = "MSG-AI-1",
            role = ChatRole.Assistant,
            text = "Hi there",
            providerID = "PROVIDER-1",
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelID = "gpt-4o",
            modelName = "GPT-4o",
            state = ChatMessageState.Delivered,
            createdAt = 1700000001000L,
        )

        repository.updateMessage(convId, deliveredAssistant)

        
        
    }

    
    
    @Test
    fun `updateMessage is a no-op when the message row was deleted`() = runTest {
        coEvery { messageDao.getById(testAccountId, "MSG-GONE") } returns null

        val deliveredAssistant = ChatMessage(
            id = "MSG-GONE",
            role = ChatRole.Assistant,
            text = "resurrected?",
            providerID = "PROVIDER-1",
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelID = "gpt-4o",
            modelName = "GPT-4o",
            state = ChatMessageState.Delivered,
            createdAt = 1700000001000L,
        )

        repository.updateMessage("CONV-1", deliveredAssistant)

        coVerify(exactly = 0) { messageDao.upsert(any()) }
    }
}
