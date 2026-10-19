package ai.oriveo.community.feature.settings

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryOrganizer
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.ProviderService
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.slot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
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

/** Drafting / organizing into items: disclosure before running, only the selected provider's user message is sent, and a failure does not switch providers. */
@OptIn(ExperimentalCoroutinesApi::class)
class MemoryExtractionDisclosureTest {

    private val dispatcher = StandardTestDispatcher()
    private lateinit var appPreferencesRepository: AppPreferencesRepository
    private val conversationRepository = mockk<ConversationRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>()
    private val firstService = mockk<ProviderService>()
    private val secondService = mockk<ProviderService>()
    private val providerListFlow = MutableStateFlow(emptyList<Provider>())

    /** Organize request stand-in: records which provider it was sent to and replies with [organizeReply] in full. */
    private val organizeTried = mutableListOf<String>()
    private var organizeReply: () -> String = { "[]" }
    private val organizeItem = MemoryItem(
        id = "item-1",
        kind = MemoryKind.FACT,
        content = "I am Alex\nPrefer short answers",
        mutationId = "mutation-1",
        deviceId = "device-1",
    )

    private val first = provider(id = "provider-a", kind = ProviderKind.OpenAI, modelName = "GPT-4.1 mini")
    private val second = provider(id = "provider-b", kind = ProviderKind.Anthropic, modelName = "Claude")

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        appPreferencesRepository = AppPreferencesRepository(FakePreferenceDao())
        every { conversationRepository.observeHasAnyWithMessages() } returns flowOf(true)
        every { providerRepository.observeAll() } returns providerListFlow
        every { providerRepository.serviceFor(match<Provider> { it.id == first.id }, any()) } returns firstService
        every { providerRepository.serviceFor(match<Provider> { it.id == second.id }, any()) } returns secondService
        every { globalSnackbarManager.show(any()) } just runs
        providerListFlow.value = listOf(first, second)
        coEvery { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            StreamEvent.Done(result = ProviderChatResult(text = "Draft from A"))
        coEvery { secondService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            StreamEvent.Done(result = ProviderChatResult(text = "Draft from B"))
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun draft_disclosure_shows_provider_model_and_scope() = runTest {
        stubConversations(conversation("c1", user("hello", first.id)))
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        val disclosure = viewModel.extractionDisclosure
        assertNotNull(disclosure)
        assertEquals(R.string.memory_extraction_title_draft, disclosure!!.titleRes)
        assertEquals(R.string.memory_extraction_scope_draft, disclosure.scopeRes)
        assertEquals(first.displayName, disclosure.providerName)
        assertCapsuleModelName(first, "gpt-a", "GPT-4.1 mini", disclosure.modelName)
        assertEquals(
            listOf(
                MemoryExtractionDisclosureLine(R.string.memory_extraction_model, listOf(first.displayName, "GPT-4.1 mini")),
                MemoryExtractionDisclosureLine(R.string.memory_extraction_scope_draft),
                MemoryExtractionDisclosureLine(R.string.memory_extraction_no_fallback),
            ),
            disclosure.bodyLines(),
        )
        assertEquals(first.id, disclosure.provider.id)
        assertEquals("gpt-a", disclosure.model.id)
        assertNull(viewModel.draftError)
        assertFalse(viewModel.isGeneratingDraft)
    }

    @Test
    fun draft_sends_nothing_until_confirmed() = runTest {
        stubConversations(conversation("c1", user("hello", first.id)))
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        assertNotNull(viewModel.extractionDisclosure)
        coVerify(exactly = 0) { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { secondService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }

        viewModel.confirmExtraction()
        advanceUntilIdle()

        coVerify(exactly = 1) { firstService.sendMessage(any(), "gpt-a", any(), any(), any(), any(), any(), any()) }
        assertNull(viewModel.extractionDisclosure)
        assertEquals("Draft from A", viewModel.editor?.text)
        assertFalse(viewModel.isGeneratingDraft)
    }

    @Test
    fun draft_cancel_sends_nothing() = runTest {
        stubConversations(conversation("c1", user("hello", first.id)))
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        viewModel.cancelExtraction()
        advanceUntilIdle()

        assertNull(viewModel.extractionDisclosure)
        assertNull(viewModel.editor)
        assertNull(viewModel.draftError)
        assertNull(viewModel.activeDraftRequestId)
        assertFalse(viewModel.isGeneratingDraft)
        coVerify(exactly = 0) { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { secondService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }

        // Confirming after cancel also sends nothing (the dialog is closed).
        viewModel.confirmExtraction()
        advanceUntilIdle()
        coVerify(exactly = 0) { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun draft_sends_only_user_messages_of_chosen_provider() = runTest {
        stubConversations(
            conversation(
                "c1",
                user("mine to A", first.id),
                assistant("reply from A", first.id),
                user("mine to B", second.id),
                user("no provider", null),
                user("second to A", first.id),
            ),
            conversation("c2", user("only B here", second.id), assistant("B reply", second.id)),
            conversation("c3", user("x".repeat(600), first.id)),
        )
        val sent = slot<List<ChatMessage>>()
        coEvery { firstService.sendMessage(any(), any(), capture(sent), any(), any(), any(), any(), any()) } returns
            StreamEvent.Done(result = ProviderChatResult(text = "Draft from A"))
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        val expected = "user: mine to A\nuser: second to A\n---\nuser: " + "x".repeat(MemoryExtraction.EXCERPT_CHARACTER_LIMIT - "user: ".length)
        assertEquals(expected, viewModel.extractionDisclosure?.excerpts)

        viewModel.confirmExtraction()
        advanceUntilIdle()

        coVerify(exactly = 0) { secondService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        val userTexts = sent.captured.filter { it.role == ChatRole.User }.map { it.text }
        assertEquals(1, userTexts.size)
        val payload = userTexts.single()
        assertTrue(payload.contains(expected))
        listOf("reply from A", "mine to B", "no provider", "only B here", "B reply").forEach { leaked ->
            assertFalse("leaked: $leaked", payload.contains(leaked))
        }
    }

    @Test
    fun draft_failure_does_not_switch_provider() = runTest {
        stubConversations(conversation("c1", user("to A", first.id), user("to B", second.id)))
        coEvery { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } throws
            IllegalStateException("provider A down")
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        coVerify(exactly = 1) { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { secondService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_generic_title, error!!.titleRes)
        assertEquals("provider A down", error.messageLiteral)
        assertNull(viewModel.editor)
        assertFalse(viewModel.isGeneratingDraft)
    }

    @Test
    fun draft_not_enough_when_no_user_message_for_provider() = runTest {
        stubConversations(
            conversation("c1", assistant("reply from A", first.id), user("to B", second.id)),
            conversation("c2", user("no provider", null)),
        )
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        assertNull(viewModel.extractionDisclosure)
        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_not_enough_title, error!!.titleRes)
        assertEquals(R.string.memory_error_not_enough_message, error.messageRes)
        coVerify(exactly = 0) { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { secondService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun organize_disclosure_shows_provider_model_and_scope() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.organize(organizeItem)
        advanceUntilIdle()

        val disclosure = viewModel.extractionDisclosure
        assertNotNull(disclosure)
        assertEquals(R.string.memory_extraction_title_organize, disclosure!!.titleRes)
        assertEquals(R.string.memory_extraction_scope_organize, disclosure.scopeRes)
        assertEquals(first.displayName, disclosure.providerName)
        assertCapsuleModelName(first, "gpt-a", "GPT-4.1 mini", disclosure.modelName)
        assertEquals(
            listOf(
                MemoryExtractionDisclosureLine(R.string.memory_extraction_model, listOf(first.displayName, "GPT-4.1 mini")),
                MemoryExtractionDisclosureLine(R.string.memory_extraction_scope_organize),
                MemoryExtractionDisclosureLine(R.string.memory_extraction_no_fallback),
            ),
            disclosure.bodyLines(),
        )
        assertEquals(first.id, disclosure.provider.id)
        assertEquals("gpt-a", disclosure.model.id)
        assertEquals(organizeItem, disclosure.organizeItem)
        assertNull(viewModel.organize)
        assertTrue(organizeTried.isEmpty())

        organizeReply = { """[{"kind":"identity","content":"I am Alex"}]""" }
        viewModel.confirmExtraction()
        assertEquals(MemoryOrganizePhase.Loading, viewModel.organize?.phase)
        advanceUntilIdle()

        assertNull(viewModel.extractionDisclosure)
        assertEquals(listOf(first.id), organizeTried)
        assertEquals(MemoryOrganizePhase.Ready, viewModel.organize?.phase)
        assertEquals(listOf("I am Alex"), viewModel.organize!!.proposals.map { it.content })
    }

    @Test
    fun organize_cancel_sends_nothing() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.organize(organizeItem)
        advanceUntilIdle()
        viewModel.cancelExtraction()
        advanceUntilIdle()

        assertNull(viewModel.extractionDisclosure)
        assertNull(viewModel.organize)
        assertTrue(organizeTried.isEmpty())

        // Confirming after cancel also sends nothing (the dialog is closed).
        viewModel.confirmExtraction()
        advanceUntilIdle()
        assertNull(viewModel.organize)
        assertTrue(organizeTried.isEmpty())
    }

    @Test
    fun organize_failure_does_not_switch_provider() = runTest {
        organizeReply = { throw IllegalStateException("provider A down") }
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.organize(organizeItem)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        assertEquals(listOf(first.id), organizeTried)
        assertEquals(MemoryOrganizePhase.Failed, viewModel.organize?.phase)
        assertNull(viewModel.extractionDisclosure)

        // An empty reply (empty after trim) also counts as a failure, with no provider switch.
        organizeTried.clear()
        organizeReply = { "  \n " }
        viewModel.organize(organizeItem)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        assertEquals(listOf(first.id), organizeTried)
        assertEquals(MemoryOrganizePhase.Failed, viewModel.organize?.phase)

        // Non-empty but no parsable item is still Empty.
        organizeReply = { "nothing to organize" }
        viewModel.organize(organizeItem)
        advanceUntilIdle()
        viewModel.confirmExtraction()
        advanceUntilIdle()

        assertEquals(MemoryOrganizePhase.Empty, viewModel.organize?.phase)
    }

    @Test
    fun draft_prepare_shows_loading_and_ignores_repeat_tap() = runTest {
        val gate = CompletableDeferred<Unit>()
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } coAnswers {
            gate.await()
            listOf(conversation("c1", user("hello", first.id)))
        }
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        runCurrent()

        assertTrue(viewModel.isGeneratingDraft)
        assertNull(viewModel.extractionDisclosure)

        viewModel.generateDraft()
        runCurrent()
        coVerify(exactly = 1) { conversationRepository.getRecentConversationsWithMessages(limit = 5) }
        assertTrue(viewModel.isGeneratingDraft)

        gate.complete(Unit)
        advanceUntilIdle()

        assertNotNull(viewModel.extractionDisclosure)
        assertFalse(viewModel.isGeneratingDraft)
        assertNull(viewModel.activeDraftRequestId)
        coVerify(exactly = 1) { conversationRepository.getRecentConversationsWithMessages(limit = 5) }
        coVerify(exactly = 0) { firstService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    /** The disclosure dialog model name uses the same display function as the chat page model chip. */
    private fun assertCapsuleModelName(provider: Provider, modelId: String, expected: String, actual: String) {
        val capsule = ModelDisplayLookup(listOf(provider)).modelDisplayName(
            providerId = provider.id,
            modelId = modelId,
            fallback = null,
        )
        assertEquals(expected, capsule)
        assertEquals(capsule, actual)
    }

    private fun createViewModel() = MemoryViewModel(
        appPreferencesRepository = appPreferencesRepository,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        globalSnackbarManager = globalSnackbarManager,
        organizerFor = { provider, _ ->
            MemoryOrganizer { _ ->
                organizeTried += provider.id
                organizeReply()
            }
        },
    )

    private fun stubConversations(vararg conversations: Conversation) {
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns conversations.toList()
    }

    private fun provider(id: String, kind: ProviderKind, modelName: String) = Provider(
        id = id,
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = listOf(AIModel(id = if (id == "provider-a") "gpt-a" else "model-b", name = modelName, isDefault = true)),
        apiKey = "sk-live",
    )

    private fun conversation(id: String, vararg messages: ChatMessage) = Conversation(
        id = id,
        title = id,
        providerID = first.id,
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-a",
        messageCount = messages.size,
        messages = messages.toList(),
    )

    private fun user(text: String, providerId: String?) = message(ChatRole.User, text, providerId)

    private fun assistant(text: String, providerId: String?) = message(ChatRole.Assistant, text, providerId)

    private fun message(role: ChatRole, text: String, providerId: String?) = ChatMessage(
        id = "${role.name}-$text".take(40),
        role = role,
        text = text,
        providerID = providerId,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4.1 mini",
        state = ChatMessageState.Delivered,
    )

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
