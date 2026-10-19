package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.context.MemoryItemSource
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryOrganizeRequest
import ai.oriveo.community.core.context.MemorySourceType
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.data.dao.MemoryItemDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.MemoryItemEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.memory.MemoryOrganizer
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.every
import io.mockk.mockk
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

@OptIn(ExperimentalCoroutinesApi::class)
class MemoryRawAndOrganizeTest {

    private val dispatcher = StandardTestDispatcher()
    private lateinit var preferenceDao: FakePreferenceDao
    private lateinit var appPreferencesRepository: AppPreferencesRepository
    private lateinit var memoryRepository: MemoryItemRepository
    private val conversationRepository = mockk<ConversationRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val providerListFlow = MutableStateFlow(emptyList<Provider>())

    /** Model request stand-in: records the request it receives and replies with [reply] in full. */
    private val organizeRequests = mutableListOf<MemoryOrganizeRequest>()
    private var reply: () -> String = { "[]" }

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        preferenceDao = FakePreferenceDao()
        appPreferencesRepository = AppPreferencesRepository(preferenceDao)
        memoryRepository = MemoryItemRepository(FakeMemoryItemDao(), preferenceDao, appPreferencesRepository)
        every { conversationRepository.observeHasAnyWithMessages() } returns MutableStateFlow(false)
        every { providerRepository.observeAll() } returns providerListFlow
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun raw_renders_active_only() = runTest {
        val active = memoryRepository.create(ACCOUNT, MemoryKind.IDENTITY, "I am Alex")
        val paused = memoryRepository.create(ACCOUNT, MemoryKind.PREFERENCE, "Short answers")
        val deleted = memoryRepository.create(ACCOUNT, MemoryKind.FACT, "Lives in Cairo")
        memoryRepository.setPaused(ACCOUNT, paused.id, true)
        memoryRepository.delete(ACCOUNT, deleted.id)
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.openRawView()

        val raw = viewModel.rawView
        assertNotNull(raw)
        assertEquals(active.content, raw!!.text)
        assertEquals(MemoryItems.rawRender(memoryRepository.list(ACCOUNT)), raw.text)
        assertNull(raw.tooLongIndex)

        // Cancel discards directly and writes no item.
        viewModel.updateRawText("changed")
        viewModel.dismissRawView()
        advanceUntilIdle()
        assertNull(viewModel.rawView)
        assertEquals("I am Alex", memoryRepository.get(ACCOUNT, active.id)!!.content)
    }

    @Test
    fun raw_unchanged_saves_nothing() = runTest {
        memoryRepository.create(ACCOUNT, MemoryKind.IDENTITY, "I am Alex")
        memoryRepository.create(ACCOUNT, MemoryKind.PROJECT, "Building Oriveo")
        val before = memoryRepository.list(ACCOUNT)
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.openRawView()
        viewModel.saveRawView()
        advanceUntilIdle()

        assertNull(viewModel.rawView)
        assertEquals(before, memoryRepository.list(ACCOUNT))
    }

    @Test
    fun raw_edit_applies_ops() = runTest {
        val a = memoryRepository.create(ACCOUNT, MemoryKind.IDENTITY, "I am Alex")
        val b = memoryRepository.create(ACCOUNT, MemoryKind.PREFERENCE, "Short answers")
        val viewModel = createViewModel()
        advanceUntilIdle()

        // Edit a, keep b, add a paragraph -> a is updated and a new fact is created.
        viewModel.openRawView()
        viewModel.updateRawText("I am Alex Young\n---\nShort answers\n---\nWorks on Android")
        viewModel.saveRawView()
        advanceUntilIdle()

        assertNull(viewModel.rawView)
        assertEquals("I am Alex Young", memoryRepository.get(ACCOUNT, a.id)!!.content)
        assertEquals(MemoryKind.IDENTITY, memoryRepository.get(ACCOUNT, a.id)!!.kind)
        assertEquals(b.mutationId, memoryRepository.get(ACCOUNT, b.id)!!.mutationId)
        val created = memoryRepository.list(ACCOUNT).single { it.id != a.id && it.id != b.id }
        assertEquals("Works on Android", created.content)
        assertEquals(MemoryKind.FACT, created.kind)
        assertEquals(MemorySourceType.MANUAL, created.source.type)
        assertEquals(created.id.lowercase(), created.id)

        // Remove b and the new paragraph -> two tombstones are written.
        viewModel.openRawView()
        viewModel.updateRawText("I am Alex Young")
        viewModel.saveRawView()
        advanceUntilIdle()

        assertEquals(MemoryStatus.ACTIVE, memoryRepository.get(ACCOUNT, a.id)!!.status)
        assertEquals(MemoryStatus.DELETED, memoryRepository.get(ACCOUNT, b.id)!!.status)
        assertEquals(MemoryStatus.DELETED, memoryRepository.get(ACCOUNT, created.id)!!.status)
    }

    @Test
    fun raw_too_long_shows_index() = runTest {
        memoryRepository.create(ACCOUNT, MemoryKind.IDENTITY, "I am Alex")
        val before = memoryRepository.list(ACCOUNT)
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.openRawView()
        viewModel.updateRawText("Changed\n---\n" + "x".repeat(MemoryItems.CONTENT_MAX_CODE_POINTS + 1))
        viewModel.saveRawView()
        advanceUntilIdle()

        // The second paragraph is too long: the user sees index + 1 = 2, the page stays, nothing is written.
        assertEquals(2, viewModel.rawView?.tooLongIndex)
        assertEquals(before, memoryRepository.list(ACCOUNT))

        // Editing again clears the hint.
        viewModel.updateRawText("Changed")
        assertNull(viewModel.rawView?.tooLongIndex)
    }

    @Test
    fun organize_proposes_and_saves_selected() = runTest {
        providerListFlow.value = listOf(sampleProvider())
        val original = memoryRepository.create(
            ACCOUNT,
            MemoryKind.FACT,
            "I am Alex\nPrefer short answers\nBuilding Oriveo",
            source = MemoryItemSource(type = MemorySourceType.MIGRATION),
        )
        reply = {
            """Here you go: [{"kind":"identity","content":"I am Alex"},""" +
                """{"kind":"preference","content":"Prefer short answers"},{"kind":"project","content":"Building Oriveo"}]"""
        }
        val viewModel = createViewModel()
        advanceUntilIdle()

        // The inline button is offered only for migrated items containing line breaks.
        assertTrue(MemoryItemRow(original).showsInlineOrganize)
        assertFalse(MemoryItemRow(original.copy(source = MemoryItemSource())).showsInlineOrganize)
        assertFalse(MemoryItemRow(original.copy(content = "One line")).showsInlineOrganize)

        // The disclosure appears first with no request sent; tapping [Send] enters Loading.
        viewModel.organize(original)
        advanceUntilIdle()
        assertNotNull(viewModel.extractionDisclosure)
        assertNull(viewModel.organize)
        assertTrue(organizeRequests.isEmpty())
        viewModel.confirmExtraction()
        assertEquals(MemoryOrganizePhase.Loading, viewModel.organize?.phase)
        advanceUntilIdle()

        // Request = organizeRequest(raw text): system is the organize prompt and the only user message is the raw text.
        val request = organizeRequests.single()
        assertEquals(MemoryItems.organizeRequest(original.content), request)
        assertEquals(ChatRole.User, request.messages.single().role)

        val state = viewModel.organize!!
        assertEquals(MemoryOrganizePhase.Ready, state.phase)
        assertEquals(listOf("I am Alex", "Prefer short answers", "Building Oriveo"), state.proposals.map { it.content })
        assertEquals(setOf(0, 1, 2), state.selected)
        assertFalse(state.keepOriginal)

        viewModel.toggleOrganizeSelection(1)
        viewModel.saveOrganized()
        advanceUntilIdle()

        assertNull(viewModel.organize)
        val created = memoryRepository.list(ACCOUNT).filter { it.id != original.id }
        assertEquals(setOf("I am Alex", "Building Oriveo"), created.map { it.content }.toSet())
        assertEquals(MemoryKind.IDENTITY, created.single { it.content == "I am Alex" }.kind)
        assertEquals(MemoryKind.PROJECT, created.single { it.content == "Building Oriveo" }.kind)
        created.forEach { item ->
            assertEquals(MemorySourceType.MANUAL, item.source.type)
            assertEquals(MemoryStatus.ACTIVE, item.status)
            assertEquals(item.id.lowercase(), item.id)
        }
        assertEquals(MemoryStatus.DELETED, memoryRepository.get(ACCOUNT, original.id)!!.status)
    }

    @Test
    fun organize_keep_original_toggle() = runTest {
        providerListFlow.value = listOf(sampleProvider())
        val original = memoryRepository.create(ACCOUNT, MemoryKind.FACT, "I am Alex\nPrefer short answers")
        reply = { """[{"kind":"identity","content":"I am Alex"},{"kind":"preference","content":"Prefer short answers"}]""" }
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.organize(original)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()
        viewModel.setOrganizeKeepOriginal(true)
        assertTrue(viewModel.organize!!.keepOriginal)
        viewModel.saveOrganized()
        advanceUntilIdle()

        val after = memoryRepository.list(ACCOUNT)
        assertEquals(3, after.size)
        assertEquals(MemoryStatus.ACTIVE, memoryRepository.get(ACCOUNT, original.id)!!.status)
        assertEquals("I am Alex\nPrefer short answers", memoryRepository.get(ACCOUNT, original.id)!!.content)

        // Cannot save with nothing ticked.
        viewModel.organize(original)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()
        viewModel.toggleOrganizeSelection(0)
        viewModel.toggleOrganizeSelection(1)
        assertFalse(viewModel.organize!!.canSave)
        viewModel.saveOrganized()
        advanceUntilIdle()
        assertNotNull(viewModel.organize)
        assertEquals(after, memoryRepository.list(ACCOUNT))
    }

    @Test
    fun organize_parse_empty_changes_nothing() = runTest {
        providerListFlow.value = listOf(sampleProvider())
        val original = memoryRepository.create(ACCOUNT, MemoryKind.FACT, "I am Alex\nPrefer short answers")
        val before = memoryRepository.list(ACCOUNT)
        reply = { "Sorry, I can't help with that." }
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.organize(original)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()
        assertEquals(MemoryOrganizePhase.Empty, viewModel.organize?.phase)
        assertFalse(viewModel.organize!!.canSave)
        viewModel.saveOrganized()
        advanceUntilIdle()
        assertEquals(before, memoryRepository.list(ACCOUNT))

        // Request failed: a one-line hint, items likewise untouched; cancel closes the sheet.
        reply = { throw IllegalStateException("boom") }
        viewModel.organize(original)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()
        assertEquals(MemoryOrganizePhase.Failed, viewModel.organize?.phase)
        viewModel.dismissOrganize()
        assertNull(viewModel.organize)
        assertEquals(before, memoryRepository.list(ACCOUNT))
    }

    @Test
    fun organize_does_not_fall_back_to_next_candidate() = runTest {
        // No provider switch: if the first candidate errors, only that one request is sent, it goes straight to Failed and items are untouched.
        providerListFlow.value = listOf(
            sampleProvider(),
            sampleProvider().copy(id = "provider-2", apiKey = "sk-live-2"),
        )
        val original = memoryRepository.create(ACCOUNT, MemoryKind.FACT, "I am Alex\nPrefer short answers")
        val before = memoryRepository.list(ACCOUNT)
        val tried = mutableListOf<String>()
        reply = { throw IllegalStateException("boom") }
        val viewModel = createViewModel(onProvider = { tried += it.id })
        advanceUntilIdle()

        viewModel.organize(original)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        assertEquals(listOf("provider-1"), tried)
        assertEquals(1, organizeRequests.size)
        assertEquals(MemoryOrganizePhase.Failed, viewModel.organize?.phase)
        viewModel.dismissOrganize()
        assertEquals(before, memoryRepository.list(ACCOUNT))
    }

    @Test
    fun organize_no_model_hint() = runTest {
        val original = memoryRepository.create(ACCOUNT, MemoryKind.FACT, "I am Alex\nPrefer short answers")
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.organize(original)
        advanceUntilIdle()

        assertEquals(MemoryOrganizePhase.NoModel, viewModel.organize?.phase)
        assertNull(viewModel.extractionDisclosure)
        assertTrue(organizeRequests.isEmpty())
        assertEquals(MemoryStatus.ACTIVE, memoryRepository.get(ACCOUNT, original.id)!!.status)
    }

    private fun createViewModel(onProvider: (Provider) -> Unit = {}) = MemoryViewModel(
        appPreferencesRepository = appPreferencesRepository,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
        memoryItemRepository = memoryRepository,
        accountIds = MutableStateFlow(ACCOUNT),
        organizerFor = { provider, _ ->
            MemoryOrganizer { request ->
                onProvider(provider)
                organizeRequests += request
                reply()
            }
        },
    )

    private fun sampleProvider() = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(AIModel(id = "gpt-4.1-mini", name = "GPT-4.1 mini", isDefault = true)),
        apiKey = "sk-live",
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

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> = values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? = values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }

    private companion object {
        const val ACCOUNT = "account-1"
    }
}
