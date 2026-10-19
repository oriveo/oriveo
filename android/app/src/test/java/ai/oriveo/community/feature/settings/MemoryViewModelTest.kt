package ai.oriveo.community.feature.settings

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.context.MemoryConflictResolution
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryServerTime
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.dao.MemoryItemDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.MemoryItemEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.memory.toEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderService
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.runs
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.koin.core.context.startKoin
import org.koin.core.context.stopKoin
import org.koin.dsl.module
import java.time.LocalDate

@OptIn(ExperimentalCoroutinesApi::class)
class MemoryViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private lateinit var appPreferencesRepository: AppPreferencesRepository
    private lateinit var preferenceDao: FakePreferenceDao
    private lateinit var memoryRepository: MemoryItemRepository
    private lateinit var memoryDao: FakeMemoryItemDao
    private val conversationRepository = mockk<ConversationRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>()
    private val providerService = mockk<ProviderService>()

    private val conversationListFlow = MutableStateFlow(emptyList<Conversation>())
    private val providerListFlow = MutableStateFlow(emptyList<Provider>())

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        preferenceDao = FakePreferenceDao()
        appPreferencesRepository = AppPreferencesRepository(preferenceDao)
        memoryDao = FakeMemoryItemDao()
        memoryRepository = MemoryItemRepository(memoryDao, preferenceDao, appPreferencesRepository)

        every { conversationRepository.observeHasAnyWithMessages() } returns conversationListFlow.map { conversations -> conversations.any { it.messageCount > 0 } }
        every { providerRepository.observeAll() } returns providerListFlow

        every { globalSnackbarManager.show(any()) } just runs
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun edit_item_id_opens_editor() = runTest {
        val fact = memoryRepository.create(ACCOUNT, MemoryKind.FACT, "Lives in Cairo")
        memoryRepository.create(ACCOUNT, MemoryKind.PREFERENCE, "Short answers")

        val viewModel = createViewModel(editItemId = fact.id)
        advanceUntilIdle()

        val editor = viewModel.editor
        assertNotNull(editor)
        assertEquals(fact.id, editor!!.itemId)
        assertEquals("Lives in Cairo", editor.text)
        assertEquals(MemoryItemGroup.About, editor.group)

        // Save goes through the repository edit: the body is updated and a fact in "About me" stays a fact.
        viewModel.updateEditorText("Lives in Giza")
        viewModel.saveEditor()
        advanceUntilIdle()
        val saved = memoryRepository.get(ACCOUNT, fact.id)!!
        assertEquals("Lives in Giza", saved.content)
        assertEquals(MemoryKind.FACT, saved.kind)
        assertNull(viewModel.editor)

        // A missing or deleted id does not open the editor.
        memoryRepository.delete(ACCOUNT, fact.id)
        val missing = createViewModel(editItemId = fact.id)
        advanceUntilIdle()
        assertNull(missing.editor)
    }

    @Test
    fun new_episodic_editor_saves_l3_with_kind_and_date() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.openNewEpisodicEditor()
        val editor = viewModel.editor!!
        assertTrue(editor.isEpisodic)
        assertEquals(MemoryKind.DECISION, editor.episodicKind)
        assertEquals(TODAY, editor.date)

        viewModel.updateEditorText("Moved to Lisbon")
        viewModel.updateEditorEpisodicKind(MemoryKind.EVENT)
        viewModel.updateEditorEpisodicKind(MemoryKind.FACT) // L3 accepts only decision / event
        viewModel.updateEditorDate(LocalDate.of(2026, 9, 3))
        viewModel.saveEditor()
        advanceUntilIdle()

        val saved = memoryRepository.list(ACCOUNT).single()
        assertEquals(MemoryLayer.EPISODIC, saved.layer)
        assertEquals(MemoryKind.EVENT, saved.kind)
        assertEquals("2026-09-03T00:00:00Z", saved.occurredAt)
        assertEquals(listOf(saved.id), buildMemoryItemListPresentation(viewModel.items.value, null).episodic.rows.map { it.item.id })

        // Editing L3: kind and date are shown, and changing the date writes back occurredAt.
        viewModel.openEditor(saved)
        assertTrue(viewModel.editor!!.isEpisodic)
        assertEquals(MemoryKind.EVENT, viewModel.editor!!.episodicKind)
        assertEquals(LocalDate.of(2026, 9, 3), viewModel.editor!!.date)
        viewModel.updateEditorDate(LocalDate.of(2026, 9, 4))
        viewModel.saveEditor()
        advanceUntilIdle()
        val edited = memoryRepository.get(ACCOUNT, saved.id)!!
        assertEquals("2026-09-04T00:00:00Z", edited.occurredAt)
        assertEquals(MemoryKind.EVENT, edited.kind)

        // Editing L2 is not the L3 editor.
        val fact = memoryRepository.create(ACCOUNT, MemoryKind.FACT, "Lives in Cairo")
        viewModel.openEditor(fact)
        assertFalse(viewModel.editor!!.isEpisodic)
        assertFalse(MemoryKind.DECISION in viewModel.editor!!.kindOptions)
    }

    @Test
    fun l3_conflict_actions_call_repository_resolution() = runTest {
        val expectations = mapOf(
            MemoryConflictResolution.USE_NEW to (MemoryStatus.ACTIVE to MemoryStatus.SUPERSEDED),
            MemoryConflictResolution.USE_OLD to (MemoryStatus.SUPERSEDED to MemoryStatus.ACTIVE),
            MemoryConflictResolution.KEEP_BOTH to (MemoryStatus.ACTIVE to MemoryStatus.ACTIVE),
        )
        expectations.entries.forEachIndexed { index, (resolution, statuses) ->
            val olderId = "0000000$index-old"
            val newerId = "0000000$index-new"
            seedConflicted(olderId, "2026-03-0${index + 1}T00:00:00Z", groupId = olderId)
            seedConflicted(newerId, "2026-09-0${index + 1}T00:00:00Z", groupId = olderId)
            val viewModel = createViewModel()
            advanceUntilIdle()

            val pair = buildMemoryItemListPresentation(viewModel.items.value, null).l3Conflicts.single { it.groupId == olderId }
            assertEquals(newerId, pair.newer.item.id)
            viewModel.resolveL3Conflict(pair, resolution)
            advanceUntilIdle()

            assertEquals(statuses.first, memoryRepository.get(ACCOUNT, newerId)!!.status)
            assertEquals(statuses.second, memoryRepository.get(ACCOUNT, olderId)!!.status)
            assertEquals(resolution == MemoryConflictResolution.USE_NEW, olderId in memoryRepository.get(ACCOUNT, newerId)!!.supersedes)
        }
    }

    private suspend fun seedConflicted(id: String, occurredAt: String, groupId: String) {
        memoryDao.upsert(
            MemoryItem(
                id = id,
                layer = MemoryLayer.EPISODIC,
                kind = MemoryKind.DECISION,
                status = MemoryStatus.CONFLICTED,
                content = "Decision $id",
                mutationId = "m-$id",
                deviceId = "device",
                conflictGroupId = groupId,
                occurredAt = occurredAt,
                createdAt = MemoryServerTime.At(occurredAt),
            ).toEntity(ACCOUNT, MemoryItemEntity.SYNC_PENDING),
        )
    }

    @Test
    fun delete_confirms_then_tombstones() = runTest {
        val item = memoryRepository.create(ACCOUNT, MemoryKind.INSTRUCTION, "Answer in Arabic")
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.requestDelete(item)
        advanceUntilIdle()
        assertEquals(item.id, viewModel.pendingDelete?.id)
        assertEquals(MemoryStatus.ACTIVE, memoryRepository.get(ACCOUNT, item.id)!!.status)

        viewModel.cancelDelete()
        advanceUntilIdle()
        assertNull(viewModel.pendingDelete)
        assertEquals(MemoryStatus.ACTIVE, memoryRepository.get(ACCOUNT, item.id)!!.status)

        viewModel.requestDelete(item)
        viewModel.confirmDelete()
        advanceUntilIdle()
        assertNull(viewModel.pendingDelete)
        assertEquals(MemoryStatus.DELETED, memoryRepository.get(ACCOUNT, item.id)!!.status)
        // The repository list contains tombstones; the displayed list filters them out.
        assertTrue(viewModel.items.value.any { it.id == item.id })
        assertTrue(buildMemoryItemListPresentation(viewModel.items.value, viewModel.deviceId).isEmpty)
    }

    @Test
    fun pin_and_pause() = runTest {
        val item = memoryRepository.create(ACCOUNT, MemoryKind.PREFERENCE, "Short answers")
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.togglePinned(item)
        advanceUntilIdle()
        assertTrue(memoryRepository.get(ACCOUNT, item.id)!!.pinned)

        viewModel.togglePaused(viewModel.items.value.single())
        advanceUntilIdle()
        val paused = memoryRepository.get(ACCOUNT, item.id)!!
        assertEquals(MemoryStatus.PAUSED, paused.status)
        assertTrue(buildMemoryItemListPresentation(viewModel.items.value, viewModel.deviceId).sections.single().rows.single().paused)

        viewModel.togglePaused(paused)
        viewModel.togglePinned(paused)
        advanceUntilIdle()
        val resumed = memoryRepository.get(ACCOUNT, item.id)!!
        assertEquals(MemoryStatus.ACTIVE, resumed.status)
        assertFalse(resumed.pinned)
    }

    @Test
    fun `new editor creates item with group kind`() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.openNewEditor(MemoryItemGroup.Instructions)
        viewModel.updateEditorText("  Always cite sources  ")
        viewModel.saveEditor()
        advanceUntilIdle()

        val created = memoryRepository.list(ACCOUNT).single()
        assertEquals(MemoryKind.INSTRUCTION, created.kind)
        assertEquals("Always cite sources", created.content)
        assertNull(viewModel.editor)
    }

    @Test
    fun `generateDraft surfaces draftError when no provider is configured`() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        assertFalse(viewModel.isGeneratingDraft)
        assertNull(viewModel.activeDraftRequestId)
        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_no_provider_title, error!!.titleRes)
        assertEquals(R.string.memory_error_no_provider_message, error.messageRes)
    }

    @Test
    fun `generateDraft surfaces draftError when no model is configured`() = runTest {
        val providerWithoutModel = sampleDraftProvider().copy(models = emptyList())
        providerListFlow.value = listOf(providerWithoutModel)
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        assertFalse(viewModel.isGeneratingDraft)
        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_no_model_title, error!!.titleRes)
        assertEquals(R.string.memory_error_no_model_message, error.messageRes)
    }

    @Test
    fun `generateDraft surfaces draftError when no recent conversations`() = runTest {
        val provider = sampleDraftProvider()
        providerListFlow.value = listOf(provider)
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns emptyList()

        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        assertFalse(viewModel.isGeneratingDraft)
        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_not_enough_title, error!!.titleRes)
        assertEquals(R.string.memory_error_not_enough_message, error.messageRes)
    }

    @Test
    fun `generateDraft applies generated text and clears generation state`() = runTest {
        val availableProvider = sampleDraftProvider()
        providerListFlow.value = listOf(availableProvider)
        conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
            sampleConversationWithMessages(),
        )
        every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.OpenAI }, any()) } returns providerService
        coEvery {
            providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } returns StreamEvent.Done(
            result = ProviderChatResult(text = "Generated profile draft"),
        )
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        // The draft result prefills a new editor (category About me) and writes no item.
        val editor = viewModel.editor
        assertNotNull(editor)
        assertNull(editor!!.itemId)
        assertEquals(MemoryItemGroup.About, editor.group)
        assertEquals("Generated profile draft", editor.text)
        assertTrue(memoryRepository.list(ACCOUNT).isEmpty())
        assertFalse(viewModel.isGeneratingDraft)
        assertNull(viewModel.activeDraftRequestId)
        assertNull(viewModel.pendingGeneratedDraft)
        assertFalse(viewModel.showDraftConflictDialog)
        assertNull(viewModel.draftError)
    }

    @Test
    fun `generateDraft sends once and reports error when first provider fails`() = runTest {
        val failing = sampleDraftProvider(id = "provider-fail", kind = ProviderKind.OpenAI)
        val working = sampleDraftProvider(id = "provider-ok", kind = ProviderKind.Anthropic)
        providerListFlow.value = listOf(failing, working)
        conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
            sampleConversationWithMessages(providerId = "provider-fail"),
            sampleConversationWithMessages(providerId = "provider-ok"),
        )

        val failService = mockk<ProviderService>()
        val okService = mockk<ProviderService>()
        every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.OpenAI }, any()) } returns failService
        every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.Anthropic }, any()) } returns okService

        coEvery {
            failService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } throws IllegalStateException("first provider down")
        coEvery {
            okService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } returns StreamEvent.Done(result = ProviderChatResult(text = "Fallback draft works"))

        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        coVerify(exactly = 1) { failService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { okService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        assertNull(viewModel.editor)
        assertFalse(viewModel.isGeneratingDraft)
        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_generic_title, error!!.titleRes)
        assertEquals("first provider down", error.messageLiteral)
    }

    @Test
    fun `generateDraft reports generic message when single provider fails without detail`() = runTest {
        val first = sampleDraftProvider(id = "first", kind = ProviderKind.OpenAI)
        val second = sampleDraftProvider(id = "second", kind = ProviderKind.Anthropic)
        providerListFlow.value = listOf(first, second)
        conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
            sampleConversationWithMessages(providerId = "first"),
        )

        val failOne = mockk<ProviderService>()
        val failTwo = mockk<ProviderService>()
        every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.OpenAI }, any()) } returns failOne
        every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.Anthropic }, any()) } returns failTwo
        coEvery { failOne.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } throws RuntimeException()
        coEvery { failTwo.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } throws RuntimeException("final boom")

        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_generic_title, error!!.titleRes)
        assertEquals(R.string.memory_error_generic_message, error.messageRes)
        assertNull(error.messageLiteral)
        assertTrue(error.args.isEmpty())
        coVerify(exactly = 0) { failTwo.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        assertFalse(viewModel.isGeneratingDraft)
    }

    @Test
    fun `generateDraft localizes provider error detail via ErrorMapper when Koin provides Context`() = runTest {
        // ProviderServiceError.userMessage is hardcoded English; it must be localized before
        // becoming a DraftError (locale-agnostic: compare against the stubbed getString value,
        // not an English keyword).
        val context = mockk<android.content.Context>()
        every { context.getString(R.string.error_rate_limited_message) } returns "そくどせいげんメッセージ"
        startKoin { modules(module { single<android.content.Context> { context } }) }
        try {
            providerListFlow.value = listOf(sampleDraftProvider())
            conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
            coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
                sampleConversationWithMessages(),
            )
            every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.OpenAI }, any()) } returns providerService
            coEvery {
                providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
            } throws ProviderServiceError.RateLimited("upstream throttled")

            val viewModel = createViewModel()
            advanceUntilIdle()

            viewModel.generateDraft()
            advanceUntilIdle()
            viewModel.confirmExtraction()
            advanceUntilIdle()

            val error = viewModel.draftError
            assertNotNull(error)
            assertEquals(R.string.memory_error_generic_title, error!!.titleRes)
            assertEquals("そくどせいげんメッセージ", error.messageLiteral)
        } finally {
            stopKoin()
        }
    }

    @Test
    fun `generateDraft falls back to raw provider message when Koin Context unavailable`() = runTest {
        // Koin isn't started in this unit test: it must fall back to the raw English string
        // without crashing (runCatching's fallback contract).
        providerListFlow.value = listOf(sampleDraftProvider())
        conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
            sampleConversationWithMessages(),
        )
        every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.OpenAI }, any()) } returns providerService
        coEvery {
            providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } throws ProviderServiceError.RateLimited("upstream throttled")

        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(
            "The provider is temporarily rate limiting this request. Please wait a moment and try again.",
            error!!.messageLiteral,
        )
    }

    @Test
    fun `generateDraft stores pending draft when user edits during generation`() = runTest {
        val availableProvider = sampleDraftProvider()
        val gate = CompletableDeferred<Unit>()
        providerListFlow.value = listOf(availableProvider)
        conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
            sampleConversationWithMessages(),
        )
        every { providerRepository.serviceFor(match<Provider> { it.kind == ProviderKind.OpenAI }, any()) } returns providerService
        coEvery {
            providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } coAnswers {
            gate.await()
            StreamEvent.Done(result = ProviderChatResult(text = "Draft from provider"))
        }
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        viewModel.confirmExtraction()
        viewModel.openNewEditor(text = "User edited while generating")
        gate.complete(Unit)
        advanceUntilIdle()

        assertFalse(viewModel.isGeneratingDraft)
        assertEquals("User edited while generating", viewModel.editor?.text)
        assertEquals("Draft from provider", viewModel.pendingGeneratedDraft)
        assertTrue(viewModel.showDraftConflictDialog)

        viewModel.applyPendingGeneratedDraft()

        assertEquals("Draft from provider", viewModel.editor?.text)
        assertNull(viewModel.pendingGeneratedDraft)
        assertFalse(viewModel.showDraftConflictDialog)
    }

    @Test
    fun `dismissDraftError clears draftError state`() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        assertNotNull(viewModel.draftError)

        viewModel.dismissDraftError()
        assertNull(viewModel.draftError)
    }

    private fun createViewModel(editItemId: String? = null) = MemoryViewModel(
        appPreferencesRepository = appPreferencesRepository,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        globalSnackbarManager = globalSnackbarManager,
        memoryItemRepository = memoryRepository,
        accountIds = MutableStateFlow(ACCOUNT),
        editItemId = editItemId,
        today = { TODAY },
    )

    private fun sampleDraftProvider(
        id: String = "provider-1",
        kind: ProviderKind = ProviderKind.OpenAI,
    ) = Provider(
        id = id,
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = listOf(AIModel(id = "gpt-4.1-mini", name = "GPT-4.1 mini", isDefault = true)),
        apiKey = "sk-live",
    )

    private fun sampleConversation(messageCount: Int) = Conversation(
        id = "conversation-1",
        title = "Recent conversation",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4.1-mini",
        messageCount = messageCount,
    )

    private fun sampleConversationWithMessages(providerId: String = "provider-1") = Conversation(
        id = "conversation-$providerId",
        title = "Conversation with messages",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4.1-mini",
        messages = listOf(
            ChatMessage(
                id = "m1",
                role = ChatRole.User,
                text = "I work on Android and Kotlin.",
                providerID = providerId,
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "GPT-4.1 mini",
                state = ChatMessageState.Delivered,
            ),
            ChatMessage(
                id = "m2",
                role = ChatRole.Assistant,
                text = "Noted. You prefer concise practical guidance.",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "GPT-4.1 mini",
                state = ChatMessageState.Delivered,
            ),
        ),
    )

    private class FakeMemoryItemDao : MemoryItemDao {
        private val rows = MutableStateFlow<Map<Pair<String, String>, MemoryItemEntity>>(emptyMap())

        override suspend fun upsert(entity: MemoryItemEntity) {
            rows.value = rows.value + ((entity.accountId to entity.id) to entity)
        }

        override suspend fun get(accountId: String, id: String): MemoryItemEntity? = rows.value[accountId to id]

        override suspend fun list(accountId: String): List<MemoryItemEntity> =
            rows.value.values.filter { it.accountId == accountId }

        override fun observe(accountId: String): Flow<List<MemoryItemEntity>> =
            rows.map { all -> all.values.filter { it.accountId == accountId } }

        override suspend fun listBySyncState(accountId: String, syncState: String): List<MemoryItemEntity> =
            list(accountId).filter { it.syncState == syncState }

        override suspend fun deleteByAccount(accountId: String) {
            rows.value = rows.value.filterKeys { it.first != accountId }
        }
    }

    private companion object {
        const val ACCOUNT = "account-1"
        val TODAY: LocalDate = LocalDate.of(2026, 10, 17)
    }

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> =
            values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? =
            values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }
}
