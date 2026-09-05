package ai.oriveo.community.feature.settings

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
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
import io.mockk.every
import io.mockk.runs
import io.mockk.just
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

@OptIn(ExperimentalCoroutinesApi::class)
class MemoryViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private lateinit var appPreferencesRepository: AppPreferencesRepository
    private lateinit var preferenceDao: FakePreferenceDao
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

        every { conversationRepository.observeHasAnyWithMessages() } returns conversationListFlow.map { conversations -> conversations.any { it.messageCount > 0 } }
        every { providerRepository.observeAll() } returns providerListFlow

        every { globalSnackbarManager.show(any()) } just runs
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `save normalizes blank memory and clears anti forget fields`() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.updateEditText("   ")
        viewModel.updateAntiForgetEnabled(true)

        viewModel.save()
        advanceUntilIdle()

        assertEquals("", appPreferencesRepository.getMemoryText())
        assertFalse(appPreferencesRepository.getMemoryAntiForgetEnabled())
        assertEquals("", appPreferencesRepository.getMemoryAntiForgetText())
        assertTrue(viewModel.showSaveSuccessDialog)
        assertEquals("", viewModel.editText)
        assertFalse(viewModel.antiForgetEnabled)
        assertFalse(viewModel.hasChanges)
    }

    @Test
    fun `save with anti-forget enabled mirrors memory text into antiForgetText`() = runTest {
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.updateEditText("I'm a backend engineer using Go.")
        viewModel.updateAntiForgetEnabled(true)

        viewModel.save()
        advanceUntilIdle()

        // antiForgetText auto-derives from editText (truncated to 200); there's no separate field anymore.
        assertEquals("I'm a backend engineer using Go.", appPreferencesRepository.getMemoryText())
        assertTrue(appPreferencesRepository.getMemoryAntiForgetEnabled())
        assertEquals("I'm a backend engineer using Go.", appPreferencesRepository.getMemoryAntiForgetText())
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
        every { providerRepository.serviceFor(ProviderKind.OpenAI) } returns providerService
        coEvery {
            providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } returns StreamEvent.Done(
            result = ProviderChatResult(text = "Generated profile draft"),
        )
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        assertEquals("Generated profile draft", viewModel.editText)
        assertFalse(viewModel.isGeneratingDraft)
        assertNull(viewModel.activeDraftRequestId)
        assertNull(viewModel.pendingGeneratedDraft)
        assertFalse(viewModel.showDraftConflictDialog)
        assertNull(viewModel.draftError)
    }

    @Test
    fun `generateDraft falls back to second provider when first fails`() = runTest {
        val failing = sampleDraftProvider(id = "provider-fail", kind = ProviderKind.OpenAI)
        val working = sampleDraftProvider(id = "provider-ok", kind = ProviderKind.Anthropic)
        providerListFlow.value = listOf(failing, working)
        conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
            sampleConversationWithMessages(),
        )

        val failService = mockk<ProviderService>()
        val okService = mockk<ProviderService>()
        every { providerRepository.serviceFor(ProviderKind.OpenAI) } returns failService
        every { providerRepository.serviceFor(ProviderKind.Anthropic) } returns okService

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

        assertEquals("Fallback draft works", viewModel.editText)
        assertFalse(viewModel.isGeneratingDraft)
        assertNull(viewModel.draftError)
    }

    @Test
    fun `generateDraft aggregates error when all providers fail`() = runTest {
        val first = sampleDraftProvider(id = "first", kind = ProviderKind.OpenAI)
        val second = sampleDraftProvider(id = "second", kind = ProviderKind.Anthropic)
        providerListFlow.value = listOf(first, second)
        conversationListFlow.value = listOf(sampleConversation(messageCount = 1))
        coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
            sampleConversationWithMessages(),
        )

        val failOne = mockk<ProviderService>()
        val failTwo = mockk<ProviderService>()
        every { providerRepository.serviceFor(ProviderKind.OpenAI) } returns failOne
        every { providerRepository.serviceFor(ProviderKind.Anthropic) } returns failTwo
        coEvery { failOne.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } throws RuntimeException("oops")
        coEvery { failTwo.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } throws RuntimeException("final boom")

        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        advanceUntilIdle()

        val error = viewModel.draftError
        assertNotNull(error)
        assertEquals(R.string.memory_error_generic_title, error!!.titleRes)
        assertEquals(R.string.memory_error_aggregated_with_detail, error.messageRes)
        assertEquals(listOf<Any>(2, "final boom"), error.args)
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
            every { providerRepository.serviceFor(ProviderKind.OpenAI) } returns providerService
            coEvery {
                providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
            } throws ProviderServiceError.RateLimited("upstream throttled")

            val viewModel = createViewModel()
            advanceUntilIdle()

            viewModel.generateDraft()
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
        every { providerRepository.serviceFor(ProviderKind.OpenAI) } returns providerService
        coEvery {
            providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } throws ProviderServiceError.RateLimited("upstream throttled")

        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
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
        every { providerRepository.serviceFor(ProviderKind.OpenAI) } returns providerService
        coEvery {
            providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any())
        } coAnswers {
            gate.await()
            StreamEvent.Done(result = ProviderChatResult(text = "Draft from provider"))
        }
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.generateDraft()
        viewModel.updateEditText("User edited while generating")
        gate.complete(Unit)
        advanceUntilIdle()

        assertFalse(viewModel.isGeneratingDraft)
        assertEquals("User edited while generating", viewModel.editText)
        assertEquals("Draft from provider", viewModel.pendingGeneratedDraft)
        assertTrue(viewModel.showDraftConflictDialog)

        viewModel.applyPendingGeneratedDraft()

        assertEquals("Draft from provider", viewModel.editText)
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

    private fun createViewModel() = MemoryViewModel(
        appPreferencesRepository = appPreferencesRepository,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        globalSnackbarManager = globalSnackbarManager,
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

    private fun sampleConversationWithMessages() = Conversation(
        id = "conversation-2",
        title = "Conversation with messages",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4.1-mini",
        messages = listOf(
            ChatMessage(
                id = "m1",
                role = ChatRole.User,
                text = "I work on Android and Kotlin.",
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
