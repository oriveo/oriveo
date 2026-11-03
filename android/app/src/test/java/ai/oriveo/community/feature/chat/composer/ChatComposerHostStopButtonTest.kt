package ai.oriveo.community.feature.chat.composer

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.feature.chat.ChatViewModel
import ai.oriveo.community.feature.chat.MessageWindowFakeStore
import ai.oriveo.community.feature.chat.stubMessageWindowLoaderDefaults
import ai.oriveo.community.ui.theme.OriveoTheme
import dev.chrisbanes.haze.HazeState
import io.mockk.coEvery
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.koin.compose.KoinApplication
import org.koin.dsl.module

/**
 * Rendering behavior of the send / stop buttons in the input bar: real [ChatViewModel], real [ChatComposerHost], real `EnhancedComposer`,
 * reads the real semantic tree, not the source code.
 *
 * Why this must be a behavior test: `ChatViewModel.isGenerating` reads `StateFlow.value`, not snapshot state.
 * After 1.2.9 moved it from the root scope into the host, the host (skippable) recomposed once when sending cleared the input and read false;
 * nothing refreshed it when the stream actually started, so the send key stayed in the "Send" state and the stop button never appeared (Google Play review feedback).
 * All 611 unit tests were green at the time, because none of them actually rendered the UI.
 *
 * The online order is "clear input (token increments) -> streamingMessageId is set later", two events in different frames.
 * With a synchronous dispatcher, writing both steps in the same frame would smooth the bug over, so `waitForIdle` explicitly splits the frames here.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatComposerHostStopButtonTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val dispatcher = UnconfinedTestDispatcher()
    private val applicationScope = kotlinx.coroutines.CoroutineScope(dispatcher + kotlinx.coroutines.SupervisorJob())
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val chatRepository = mockk<ChatRepository>()
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val windowStore = MessageWindowFakeStore()

    /** The current streaming message id of this conversation; tests set it directly, equivalent to ChatRepository setting / clearing it. */
    private val streamingMessageId = MutableStateFlow<String?>(null)

    private var provider = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(
            AIModel(
                id = "gpt-4o-mini",
                name = "GPT-4o mini",
                isDefault = true,
                capabilities = listOf(ModelCapability.Text),
            ),
        ),
    )

    private var conversation = Conversation(
        id = CONVERSATION_ID,
        title = "Stop button test",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o-mini",
        messages = emptyList(),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        coEvery { providerRepository.getById("provider-1") } returns provider
        every { providerRepository.currentCapabilityPartitionId() } returns "test-partition"
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any(), "test-partition") } returns null
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(false)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("")
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } just runs
        every { chatStreamingManager.sessionsVersion } returns MutableStateFlow(0L)
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns streamingMessageId
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
        every { conversationRepository.observeMetadata(CONVERSATION_ID) } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages(CONVERSATION_ID) } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow(CONVERSATION_ID, any()) } returns conversation
        coEvery { conversationRepository.updateDraft(any(), any()) } returns Unit
        windowStore.put(CONVERSATION_ID, conversation.messages)
    }

    @After
    fun tearDown() {
        // KoinApplication starts a process-wide global instance; without stopping it, the next case throws KoinApplicationAlreadyStartedException.
        org.koin.core.context.stopKoin()
        Dispatchers.resetMain()
    }

    @Test
    fun `stop button appears when the stream starts after the host already recomposed`() {
        val viewModel = launchHost()
        val voice = context().getString(ai.oriveo.community.R.string.voice_conversation_start_a11y)
        val stop = context().getString(ai.oriveo.community.R.string.stop)
        // An empty draft shows ≋ where the grey ↑ used to be.
        composeRule.onNodeWithContentDescription(voice).assertExists()
        composeRule.onNodeWithContentDescription(stop).assertDoesNotExist()

        // First frame: sending clears the input (token increments), and the host recomposes once before the stream has started --
        // this is exactly the moment the old implementation read isGenerating as false and stayed stale from then on.
        composeRule.runOnIdle { viewModel.restoreInputText("") }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(stop).assertDoesNotExist()

        // Next frame: ChatRepository sets streamingMessageId. The host has no other source of invalidation,
        // so it can only learn about this change by subscribing to it itself.
        composeRule.runOnIdle { streamingMessageId.value = "assistant-1" }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription(stop).assertExists()
        composeRule.onNodeWithContentDescription(voice).assertDoesNotExist()
    }

    @Test
    fun `voice entry comes back when the stream ends on an empty draft`() {
        val viewModel = launchHost()
        val send = context().getString(ai.oriveo.community.R.string.voice_conversation_start_a11y)
        val stop = context().getString(ai.oriveo.community.R.string.stop)

        composeRule.runOnIdle { viewModel.restoreInputText("") }
        composeRule.waitForIdle()
        composeRule.runOnIdle { streamingMessageId.value = "assistant-1" }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(stop).assertExists()

        composeRule.runOnIdle { streamingMessageId.value = null }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription(send).assertExists()
        composeRule.onNodeWithContentDescription(stop).assertDoesNotExist()
    }

    @Test
    fun `tapping stop stops the current conversation stream`() {
        val viewModel = launchHost()
        val stop = context().getString(ai.oriveo.community.R.string.stop)

        composeRule.runOnIdle { viewModel.restoreInputText("") }
        composeRule.waitForIdle()
        composeRule.runOnIdle { streamingMessageId.value = "assistant-1" }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription(stop).performClick()
        composeRule.waitForIdle()

        verify(exactly = 1) { chatStreamingManager.stopStream(CONVERSATION_ID) }
    }

    @Test
    fun `typing turns voice into send and voice tap emits the placeholder request`() {
        val viewModel = launchHost()
        val voice = context().getString(ai.oriveo.community.R.string.voice_conversation_start_a11y)
        val send = context().getString(ai.oriveo.community.R.string.send)
        val requests = mutableListOf<Unit>()
        val job = applicationScope.launch { viewModel.voice.requests.collect { requests += it } }
        try {
            composeRule.onNodeWithContentDescription(voice).performClick()
            composeRule.waitForIdle()
            assertEquals(1, requests.size)

            composeRule.runOnIdle { viewModel.restoreInputText("hello") }
            composeRule.waitForIdle()
            composeRule.onNodeWithContentDescription(send).assertExists()
            composeRule.onNodeWithContentDescription(voice).assertDoesNotExist()
        } finally {
            job.cancel()
        }
    }

    @Test
    fun `image only model keeps the grey send on an empty draft`() {
        provider = provider.copy(
            models = listOf(
                AIModel(id = "gpt-image-1", name = "Image", isDefault = true, capabilities = listOf(ModelCapability.ImageGen)),
            ),
        )
        conversation = conversation.copy(modelID = "gpt-image-1")
        every { conversationRepository.observeMetadata(CONVERSATION_ID) } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages(CONVERSATION_ID) } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow(CONVERSATION_ID, any()) } returns conversation
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        coEvery { providerRepository.getById("provider-1") } returns provider
        launchHost()
        composeRule.onNodeWithContentDescription(context().getString(ai.oriveo.community.R.string.send)).assertExists()
        composeRule.onNodeWithContentDescription(
            context().getString(ai.oriveo.community.R.string.voice_conversation_start_a11y),
        ).assertDoesNotExist()
    }

    private fun context(): Context = activity

    private fun launchHost(): ChatViewModel {
        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to CONVERSATION_ID)),
            context = mockk<Context>(relaxed = true),
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            noteRepository = mockk(relaxed = true),
            chatStreamingManager = chatStreamingManager,
            skillRepository = skillRepository,
            attachmentProcessor = mockk(relaxed = true),
            globalSnackbarManager = globalSnackbarManager,
            applicationScope = applicationScope,
        )
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            // ChatComposerHost / EnhancedComposer take ProviderRepository and AppPreferencesRepository via koinInject, the same mocks injected by the test.
            KoinApplication(application = { modules(module {
                single<ProviderRepository> { providerRepository }
                single<AppPreferencesRepository> { appPreferencesRepository }
            }) }) {
                OriveoTheme(darkTheme = false) {
                    ChatComposerHost(
                        viewModel = viewModel,
                        activeProvider = provider,
                        conversationId = CONVERSATION_ID,
                        conversationSkillIds = emptyList(),
                        sendingBlockedByLoadState = false,
                        hazeState = HazeState(),
                        trueTransparentBlurEnabled = false,
                        onOverlayHeightChange = {},
                        onNavigateToProviderSetup = {},
                        onNavigateToProviderDetail = {},
                        onNavigateToSkillEdit = {},
                    )
                }
            }
        }
        composeRule.waitForIdle()
        return viewModel
    }

    private lateinit var activity: ComponentActivity

    private companion object {
        const val CONVERSATION_ID = "conversation-1"
    }
}
