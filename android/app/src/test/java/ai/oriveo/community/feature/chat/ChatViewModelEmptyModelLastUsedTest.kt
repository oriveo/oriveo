package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.streaming.ChatStreamingManager
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** A conversation with an empty modelID takes the last-used model that points at its own connection through the production ChatViewModel path, not the catalog default. */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelEmptyModelLastUsedTest {

    private val dispatcher = StandardTestDispatcher()
    private val applicationScope = kotlinx.coroutines.CoroutineScope(dispatcher + kotlinx.coroutines.SupervisorJob())
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)
    private val windowStore = MessageWindowFakeStore()

    private val provider = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        apiKey = "sk-test",
        status = ProviderConnectionState.Connected,
        models = listOf(
            AIModel(id = "gpt-next", name = "GPT Next"),
            AIModel(id = "gpt-mini", name = "GPT Mini"),
        ),
    )
    private val conversation = Conversation(
        id = "conversation-empty",
        title = "Empty model",
        providerID = provider.id,
        providerKind = ProviderKind.OpenAI,
        modelID = "",
        messages = emptyList(),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-mini","retiredModels":[],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"},"gpt-mini":{"canonicalModelId":"gpt-mini","displayName":"GPT Mini"}}}}}""")
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        coEvery { providerRepository.getById(provider.id) } returns provider
        every { providerRepository.currentCapabilityPartitionId() } returns "test-partition"
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any(), "test-partition") } returns null
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(false)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("")
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } just runs
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>(), any()) } returns Unit
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow(null)
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
        coEvery { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) } returns Unit
        every { conversationRepository.observeMetadata(conversation.id) } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages(conversation.id) } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow(conversation.id, any()) } returns conversation
        windowStore.put(conversation.id, conversation.messages)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        MetadataTestFixtures.clear()
    }

    @Test
    fun `empty model conversation picks the last used model of its own connection`() = runTest {
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(LastUsedModelRef(provider.id, "gpt-next"))

        val viewModel = createViewModel()
        advanceUntilIdle()

        assertEquals("gpt-next", viewModel.conversationState.model?.id)
    }

    @Test
    fun `empty model conversation without a last used model on its connection takes the catalog default`() = runTest {
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(LastUsedModelRef("provider-other", "gpt-next"))

        val viewModel = createViewModel()
        advanceUntilIdle()

        assertEquals("gpt-mini", viewModel.conversationState.model?.id)
    }

    @Test
    fun `new chat with summary writes the current conversation model as last used before resetting`() = runTest {
        // Last used points at another connection; a new chat with summary first records the current conversation's connection and model as last used.
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(LastUsedModelRef("provider-other", "gpt-next"))
        val viewModel = createViewModel()
        advanceUntilIdle()
        assertEquals("gpt-mini", viewModel.conversationState.model?.id)

        viewModel.startNewChatKeepingModel()
        advanceUntilIdle()

        verify(exactly = 1) { appPreferencesRepository.primeLastUsedModel(provider.id, "gpt-mini") }
        coVerify(exactly = 1) {
            appPreferencesRepository.setLastUsedModel(provider.id, match<AIModel> { it.id == "gpt-mini" }, ProviderKind.OpenAI)
        }
    }

    @Test
    fun `new chat with summary on a connection missing credentials writes nothing and stays`() = runTest {
        // A connection missing credentials: a new chat with summary neither records last used nor opens a new chat, and returns the connection id so the caller can open its detail page.
        val noKey = provider.copy(status = ProviderConnectionState.Issue.missingCredential(ProviderAuthMode.ApiKey))
        every { providerRepository.observeAll() } returns flowOf(listOf(noKey))
        coEvery { providerRepository.getById(provider.id) } returns noKey
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        val viewModel = createViewModel()
        advanceUntilIdle()
        assertEquals(provider.id, viewModel.conversationState.provider?.id)

        val blocked = viewModel.startNewChatKeepingModel()
        advanceUntilIdle()

        assertEquals(provider.id, blocked)
        verify(exactly = 0) { appPreferencesRepository.primeLastUsedModel(any(), any()) }
        coVerify(exactly = 0) { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>(), any()) }
        assertEquals(provider.id, viewModel.conversationState.provider?.id)
    }

    @Test
    fun `new chat with summary on an unsendable model writes nothing and opens on its own connection chain`() = runTest {
        // The conversation model is retired (unsendable): last used is not written; the new chat opens on
        // this connection's own chain (catalog default gpt-mini) and does not follow a last-used model
        // that points at another connection.
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-mini","retiredModels":[{"id":"gpt-gone","displayName":"GPT Gone","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-mini"}],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"},"gpt-mini":{"canonicalModelId":"gpt-mini","displayName":"GPT Mini"}}}}}""")
        val withMissing = provider.copy(models = provider.models + AIModel(id = "gpt-gone", name = "GPT Gone"))
        val other = provider.copy(id = "provider-2")
        every { providerRepository.observeAll() } returns flowOf(listOf(withMissing, other))
        coEvery { providerRepository.getById(provider.id) } returns withMissing
        every { conversationRepository.observeMetadata(conversation.id) } returns flowOf(conversation.copy(modelID = "gpt-gone"))
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(LastUsedModelRef(other.id, "gpt-next"))
        val viewModel = createViewModel()
        advanceUntilIdle()
        assertEquals("gpt-gone", viewModel.conversationState.model?.id)
        assertEquals(true, viewModel.conversationState.isSendBlocked)

        val blocked = viewModel.startNewChatKeepingModel()
        advanceUntilIdle()

        assertEquals(null, blocked)
        verify(exactly = 0) { appPreferencesRepository.primeLastUsedModel(any(), any()) }
        coVerify(exactly = 0) { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>(), any()) }
        assertEquals(null, viewModel.conversation.value.conversation)
        assertEquals(provider.id, viewModel.activeProviderId)
        assertEquals("gpt-mini", viewModel.activeModelId)
    }

    private fun createViewModel(): ChatViewModel = ChatViewModel(
        savedStateHandle = SavedStateHandle(mapOf("conversationId" to conversation.id)),
        context = mockk<Context>(relaxed = true),
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        noteRepository = mockk(relaxed = true),
        chatStreamingManager = chatStreamingManager,
        skillRepository = mockk(relaxed = true),
        attachmentProcessor = mockk(relaxed = true),
        globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
        applicationScope = applicationScope,
    )
}
