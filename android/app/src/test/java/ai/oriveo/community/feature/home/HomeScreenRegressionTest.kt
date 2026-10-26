package ai.oriveo.community.feature.home

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.NoteSummary
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.feature.home.folders.folderDetailShouldNavigateBack
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.util.Calendar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Regression locks for a family of home screen bugs.
 * Each one corresponds to a real, reproducible symptom, and the assertion describes the symptom rather than the
 * implementation.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeScreenRegressionTest {

    // ── Grouping / paging (Earlier remainder, window crossing midnight) ──

    @Test
    fun `earlier section with only pinned rows leaves no empty header and no endless show more`() {
        val start = defaultRecentStartMillis()
        // Three conversations from 30 days ago, all pinned: the display layer filters them out, but they are loaded and must not count toward the remainder
        val sections = buildHomeConversationSections(
            conversations = emptyList(),
            earlierTotalCount = 3,
            loadedEarlierCount = 3,
            recentStartMillis = start,
        )
        assertTrue(sections.none { it.group == DateGroup.Earlier })
    }

    @Test
    fun `earlier remaining counts only rows the database has not loaded yet`() {
        val start = defaultRecentStartMillis()
        val old = (1..8).map { conversation("old-$it", updatedAt = start - it * DAY_MS) }
        // 25 Earlier rows in the database, 10 loaded (2 of them pinned and filtered by the display layer) → 8 shown, remainder 15
        val sections = buildHomeConversationSections(
            conversations = old,
            earlierTotalCount = 25,
            loadedEarlierCount = 10,
            recentStartMillis = start,
        )
        val earlier = sections.single { it.group == DateGroup.Earlier }
        assertEquals(8, earlier.conversations.size)
        assertEquals(15, earlier.remainingCount)
    }

    @Test
    fun `earlier boundary follows the window start the sql used`() {
        val now = System.currentTimeMillis()
        val start = defaultRecentStartMillis(now)
        val justInside = conversation("inside", updatedAt = start + 1)
        val justOutside = conversation("outside", updatedAt = start - 1)

        val grouped = groupConversationsByDate(listOf(justInside, justOutside), recentStartMillis = start).toMap()

        assertEquals(listOf("outside"), grouped[DateGroup.Earlier].orEmpty().map { it.id })
        assertTrue(grouped[DateGroup.Earlier].orEmpty().none { it.id == "inside" })
    }

    @Test
    fun `recent window starts at local midnight seven days ago and ticks at the next midnight`() {
        val calendar = Calendar.getInstance().apply {
            set(2026, Calendar.SEPTEMBER, 11, 23, 59, 30)
            set(Calendar.MILLISECOND, 0)
        }
        val now = calendar.timeInMillis
        val expectedStart = Calendar.getInstance().apply {
            set(2026, Calendar.SEPTEMBER, 4, 0, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        assertEquals(expectedStart, defaultRecentStartMillis(now))
        assertEquals(30_000L, millisUntilNextLocalMidnight(now))
    }

    // ── Empty state / search ──

    @Test
    fun `all conversations inside folders do not show the no conversations illustration`() {
        assertFalse(
            homeShowsConversationEmptyState(
                initialContentLoaded = true,
                hasProviders = true,
                topLevelEmpty = true,
                folderCount = 2,
                showingSearchResults = false,
                searchInFlight = false,
            ),
        )
        assertTrue(
            homeShowsConversationEmptyState(
                initialContentLoaded = true,
                hasProviders = true,
                topLevelEmpty = true,
                folderCount = 0,
                showingSearchResults = false,
                searchInFlight = false,
            ),
        )
    }

    @Test
    fun `search does not flash no results while the query is still in flight`() {
        assertFalse(
            homeShowsConversationEmptyState(
                initialContentLoaded = true,
                hasProviders = true,
                topLevelEmpty = true,
                folderCount = 3,
                showingSearchResults = true,
                searchInFlight = true,
            ),
        )
        // The query has returned with no hits: only now is "no results" shown, regardless of how many folders exist
        assertTrue(
            homeShowsConversationEmptyState(
                initialContentLoaded = true,
                hasProviders = true,
                topLevelEmpty = true,
                folderCount = 3,
                showingSearchResults = true,
                searchInFlight = false,
            ),
        )
    }

    @Test
    fun `opening search without typing keeps folders and pinned visible`() {
        assertFalse(homeShowsSearchResults(isSearching = true, query = ""))
        assertFalse(homeShowsSearchResults(isSearching = true, query = "   "))
        assertFalse(homeShowsSearchResults(isSearching = false, query = "alpha"))
        assertTrue(homeShowsSearchResults(isSearching = true, query = "a"))
    }

    // ── Folder detail ──

    @Test
    fun `folder detail waits for the first load before deciding the folder is gone`() {
        // On a fresh ViewModel's first frame folders is still empty: that must not count as "folder gone" and bounce the user home
        assertFalse(folderDetailShouldNavigateBack(contentLoaded = false, folderExists = false))
        assertFalse(folderDetailShouldNavigateBack(contentLoaded = true, folderExists = true))
        assertTrue(folderDetailShouldNavigateBack(contentLoaded = true, folderExists = false))
    }

    // ── ViewModel ──

    private val dispatcher = StandardTestDispatcher()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val folderRepository = mockk<ai.oriveo.community.core.data.repository.FolderRepository>()
    private val noteRepository = mockk<ai.oriveo.community.core.data.repository.NoteRepository>(relaxed = true)
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null
        every { appPreferencesRepository.pinnedConversationIds } returns flowOf(emptyList())
        every { providerRepository.observeAll() } returns flowOf(emptyList())
        every { conversationRepository.observeAll() } returns flowOf(emptyList())
        every { conversationRepository.observeUngroupedEarlierCount(any()) } returns flowOf(0)
        every { conversationRepository.search(any()) } returns flowOf(emptyList())
        every { folderRepository.observeAll() } returns flowOf(emptyList())
        every { noteRepository.observeActiveSummary() } returns flowOf(NoteSummary(0, null))
        coEvery { folderRepository.migrateColorTags() } returns Unit
        coEvery { skillRepository.refreshAll() } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>(), any()) } returns Unit
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } returns Unit
        coEvery { conversationRepository.currentMonthlyCostTotal() } returns 0.0
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `fallback step skips a connection whose enabled models are all retired`() = runTest {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-legacy","retiredModels":[{"id":"gpt-legacy","displayName":"GPT Legacy","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{"gpt-next":"gpt-next"},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"}}}}}""")
        val retiredOnly = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-legacy", name = "GPT Legacy", isDefault = true)),
            apiKey = "sk-test",
        )
        val usable = Provider(
            id = "provider-2",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-next", name = "GPT Next")),
            apiKey = "sk-test",
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(retiredOnly, usable))
        val viewModel = createViewModel()
        backgroundScope.launch { viewModel.providers.collect {} }
        advanceUntilIdle()

        val active = viewModel.ensureActiveModelWithFreeFallback {}

        assertEquals("provider-2", active?.provider?.id)
        assertEquals("gpt-next", active?.model?.id)
        coVerify(exactly = 0) { appPreferencesRepository.setLastUsedModel("provider-1", any<AIModel>(), any()) }
    }

    @Test
    fun `empty new chat chain with a connection opens the model picker`() = runTest {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-next","retiredModels":[{"id":"gpt-legacy","displayName":"GPT Legacy","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"}}}}}""")
        val retiredOnly = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-legacy", name = "GPT Legacy")),
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(retiredOnly))
        val viewModel = createViewModel()
        backgroundScope.launch { viewModel.providers.collect {} }
        advanceUntilIdle()
        var missingProviderCalls = 0

        val active = viewModel.ensureActiveModelWithFreeFallback { missingProviderCalls++ }

        // An empty chain with a connection opens the model picker instead of the add-connection flow
        assertNull(active)
        assertTrue(viewModel.showModelPicker)
        assertEquals(0, missingProviderCalls)
    }

    @Test
    fun `empty new chat chain does not open the model picker from voice planning or creation`() = runTest {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-next","retiredModels":[{"id":"gpt-legacy","displayName":"GPT Legacy","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"}}}}}""")
        val retiredOnly = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-legacy", name = "GPT Legacy")),
            apiKey = "sk-test",
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(retiredOnly))
        val viewModel = createViewModel()
        backgroundScope.launch { viewModel.providers.collect {} }
        advanceUntilIdle()

        // Voice planning and creation only read the model: an empty chain returns null and never opens the
        // picker (only the send entries do)
        assertNull(viewModel.plannedVoiceConversation())
        assertNull(viewModel.createVoiceConversation())
        assertFalse(viewModel.showModelPicker)
    }

    @Test
    fun `folder new chat works without anyone collecting the active model`() = runTest {
        // FolderDetail uses its own HomeViewModel and nobody subscribes to activeModelState
        val model = AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true)
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(model),
            catalogModels = listOf(model),
            apiKey = "sk-test",
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(LastUsedModelRef("provider-1", "gpt-4.1"))
        coEvery {
            conversationRepository.createDraft(
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI,
                modelID = any(),
                title = any(),
                folderID = "folder-1",
                skillId = any(),
                useMemory = any(),
            )
        } returns Conversation(id = "new-chat", title = "New Chat", providerID = "provider-1", providerKind = ProviderKind.OpenAI, modelID = "gpt-4.1")
        val viewModel = createViewModel()
        var createdId: String? = null

        viewModel.createConversationInFolder("folder-1") { createdId = it }
        advanceUntilIdle()

        assertEquals("new-chat", createdId)
        coVerify(exactly = 1) {
            conversationRepository.createDraft(
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI,
                modelID = any(),
                title = any(),
                folderID = "folder-1",
                skillId = any(),
                useMemory = any(),
            )
        }
    }

    @Test
    fun home_empty_send_reuses_single_draft() = runTest {
        // Tapping up on an empty draft twice goes through the real ConversationRepository (in-memory DAO): only one
        // empty draft row remains and it carries the currently selected model
        val model = AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true)
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(model),
            catalogModels = listOf(model),
            apiKey = "sk-test",
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(LastUsedModelRef("provider-1", "gpt-4.1"))
        val rows = mutableListOf<ConversationEntity>()
        val dao = mockk<ConversationDao>(relaxed = true)
        coEvery { dao.upsert(any()) } coAnswers {
            val row = firstArg<ConversationEntity>()
            rows.removeAll { it.id == row.id }
            rows += row
        }
        coEvery { dao.update(any()) } coAnswers {
            val row = firstArg<ConversationEntity>()
            rows.replaceAll { if (it.id == row.id) row else it }
        }
        coEvery { dao.findFirstEmptyDraft(any()) } coAnswers {
            rows.filter { it.accountId == firstArg<String>() && it.isPureEmptyDraft() }.maxByOrNull { it.updatedAt }
        }
        val realRepository = ConversationRepository(dao, mockk(relaxed = true))
        // The rest of the home screen stays on mocks; both conversation entry points forward to the real repository,
        // so the old createDraft path would leave an extra row
        coEvery { conversationRepository.findOrCreateDraft(any(), any(), any()) } coAnswers {
            realRepository.findOrCreateDraft(firstArg(), secondArg(), thirdArg())
        }
        coEvery { conversationRepository.createDraft(any(), any(), any(), any(), any(), any(), any()) } coAnswers {
            realRepository.createDraft(firstArg(), secondArg(), thirdArg())
        }
        val viewModel = createViewModel()
        // The home screen subscribes to activeModelState (the pill shows exactly that)
        backgroundScope.launch { viewModel.activeModelState.collect {} }
        advanceUntilIdle()
        val opened = mutableListOf<String>()

        repeat(2) {
            viewModel.sendFromHero(onConversationCreated = { opened += it }, onConversationCreatedAutoSend = {}, onMissingProvider = {})
            advanceUntilIdle()
        }

        assertEquals(2, opened.size)
        assertEquals(1, rows.count { it.isDraft })
        assertEquals(1, rows.size)
        assertEquals(opened[0], opened[1])
        assertEquals("gpt-4.1", rows.single().modelID)
    }

    @Test
    fun home_empty_send_skips_skill_and_folder_drafts() = runTest {
        // With an existing skill draft and folder draft, tapping up on an empty draft creates a plain draft row and
        // does not take the user into a skill or folder conversation
        val model = AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true)
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(model),
            catalogModels = listOf(model),
            apiKey = "sk-test",
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(LastUsedModelRef("provider-1", "gpt-4.1"))
        val rows = mutableListOf<ConversationEntity>()
        val dao = mockk<ConversationDao>(relaxed = true)
        coEvery { dao.upsert(any()) } coAnswers {
            val row = firstArg<ConversationEntity>()
            rows.removeAll { it.id == row.id }
            rows += row
        }
        coEvery { dao.update(any()) } coAnswers {
            val row = firstArg<ConversationEntity>()
            rows.replaceAll { if (it.id == row.id) row else it }
        }
        // Same criterion as the SQL pinned by the real Room test in ConversationDaoTest
        coEvery { dao.findFirstEmptyDraft(any()) } coAnswers {
            rows.filter { it.accountId == firstArg<String>() && it.isPureEmptyDraft() }.maxByOrNull { it.updatedAt }
        }
        val realRepository = ConversationRepository(dao, mockk(relaxed = true))
        val skillDraft = realRepository.createDraft("provider-1", ProviderKind.OpenAI, "gpt-4.1", title = "Translator", skillId = "skill-1")
        val folderDraft = realRepository.createDraft("provider-1", ProviderKind.OpenAI, "gpt-4.1", folderID = "folder-1")
        var viewModelRef: HomeViewModel? = null
        var sendingWhileCreating: Boolean? = null
        coEvery { conversationRepository.findOrCreateDraft(any(), any(), any()) } coAnswers {
            sendingWhileCreating = viewModelRef?.isSendingFromHero
            realRepository.findOrCreateDraft(firstArg(), secondArg(), thirdArg())
        }
        val viewModel = createViewModel().also { viewModelRef = it }
        backgroundScope.launch { viewModel.activeModelState.collect {} }
        advanceUntilIdle()
        val opened = mutableListOf<String>()

        viewModel.sendFromHero(onConversationCreated = { opened += it }, onConversationCreatedAutoSend = {}, onMissingProvider = {})
        advanceUntilIdle()

        // The empty-draft branch does not enter the sending state, so the voice entry never flickers away
        assertEquals(false, sendingWhileCreating)
        assertEquals(1, opened.size)
        assertTrue(opened.single() != skillDraft.id && opened.single() != folderDraft.id)
        assertEquals(3, rows.size)
        val created = rows.single { it.id == opened.single() }
        assertNull(created.skillId)
        assertNull(created.folderID)
        assertEquals("gpt-4.1", created.modelID)
    }

    @Test
    fun `empty hero send without a connection asks for provider setup`() = runTest {
        // Tapping up always goes through onSend then sendFromHero: with no connection the page is asked to set one up
        val viewModel = createViewModel()
        var missingProviderCalls = 0
        val opened = mutableListOf<String>()

        viewModel.sendFromHero(onConversationCreated = { opened += it }, onConversationCreatedAutoSend = {}, onMissingProvider = { missingProviderCalls++ })
        advanceUntilIdle()

        assertEquals(1, missingProviderCalls)
        assertTrue(opened.isEmpty())
    }

    @Test
    fun `notes entry count and latest title come from a single projected subscription`() = runTest {
        val viewModel = createViewModel()

        backgroundScope.launch { viewModel.activeNoteCount.collect {} }
        backgroundScope.launch { viewModel.latestNoteTitle.collect {} }
        advanceUntilIdle()

        // The value assertions live in HomeRecompositionScopeTest (where defaultDispatcher is an
        // advanceable TestDispatcher) and NoteSummaryProjectionTest (a real Room database); this one
        // only pins the subscription surface.
        // Two separate subscriptions used to map every change through toDomain twice, on the main thread
        verify(exactly = 1) { noteRepository.observeActiveSummary() }
        // The card only needs one number and one title: it must not go back to the SELECT * observeActive()
        verify(exactly = 0) { noteRepository.observeActive() }
    }

    /** The findFirstEmptyDraft SQL criterion (having no messages is satisfied naturally by the in-memory table). */
    private fun ConversationEntity.isPureEmptyDraft() =
        isDraft && draftText.isEmpty() && skillId.isNullOrEmpty() && folderID.isNullOrEmpty() && !hasCustomTitle

    private fun createViewModel() = HomeViewModel(
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        folderRepository = folderRepository,
        noteRepository = noteRepository,
        globalSnackbarManager = globalSnackbarManager,
        skillRepository = skillRepository,
        chatStreamingManager = chatStreamingManager,
        ioDispatcher = dispatcher,
    )

    private fun conversation(id: String, updatedAt: Long) = Conversation(
        id = id,
        title = id,
        providerID = "p1",
        providerKind = ProviderKind.OpenAI,
        modelID = "m1",
        updatedAt = updatedAt,
        isDraft = false,
    )

    private companion object {
        const val DAY_MS = 24 * 60 * 60 * 1000L
    }
}
