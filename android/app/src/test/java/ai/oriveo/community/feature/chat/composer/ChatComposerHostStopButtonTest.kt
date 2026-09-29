package ai.oriveo.community.feature.chat.composer

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
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.lifecycle.SavedStateHandle
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
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.compose.KoinApplication
import org.koin.dsl.module
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Rendering behavior of the composer's send / stop button: a real [ChatViewModel], a real
 * [ChatComposerHost] and a real `EnhancedComposer`, asserted against the semantics tree rather
 * than the source text.
 *
 * Why this must be a rendering test: `ChatViewModel.isGenerating` reads `StateFlow.value`, which is
 * not snapshot state. The host is skippable; clearing the input on send recomposes it once before the
 * stream is marked active, it reads `false`, and nothing invalidates it afterwards. The send button
 * then never turns into the stop button. Source-text assertions cannot catch that.
 *
 * In production the two steps ("input cleared" and, a little later, "streamingMessageId set") land in
 * different frames. Writing both in the same frame under a synchronous dispatcher would hide the bug,
 * so this test separates them with an explicit `waitForIdle`.
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

    /** The conversation's active streaming message id; flipping it is what ChatRepository does. */
    private val streamingMessageId = MutableStateFlow<String?>(null)

    private val provider = Provider(
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

    private val conversation = Conversation(
        id = CONVERSATION_ID,
        title = "Stop button test",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o-mini",
        messages = emptyList(),
    )

    private lateinit var activity: ComponentActivity

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
        // KoinApplication starts a process-wide instance; leaving it running fails the next test with
        // KoinApplicationAlreadyStartedException.
        org.koin.core.context.stopKoin()
        Dispatchers.resetMain()
    }

    @Test
    fun `stop button appears when the stream starts after the host already recomposed`() {
        val viewModel = launchHost()
        val send = activity.getString(ai.oriveo.community.R.string.send)
        val stop = activity.getString(ai.oriveo.community.R.string.stop)
        composeRule.onNodeWithContentDescription(send).assertExists()
        composeRule.onNodeWithContentDescription(stop).assertDoesNotExist()

        // Frame one: sending clears the input (restore token bumps) and the host recomposes while the
        // stream has not started yet. This is the recomposition that used to freeze isGenerating=false.
        composeRule.runOnIdle { viewModel.restoreInputText("") }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(stop).assertDoesNotExist()

        // A later frame: ChatRepository marks the stream active. The host has no other source of
        // invalidation, so it can only react by subscribing to the change itself.
        composeRule.runOnIdle { streamingMessageId.value = "assistant-1" }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription(stop).assertExists()
        composeRule.onNodeWithContentDescription(send).assertDoesNotExist()
    }

    @Test
    fun `send button comes back when the stream ends`() {
        val viewModel = launchHost()
        val send = activity.getString(ai.oriveo.community.R.string.send)
        val stop = activity.getString(ai.oriveo.community.R.string.stop)

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
        val stop = activity.getString(ai.oriveo.community.R.string.stop)

        composeRule.runOnIdle { viewModel.restoreInputText("") }
        composeRule.waitForIdle()
        composeRule.runOnIdle { streamingMessageId.value = "assistant-1" }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription(stop).performClick()
        composeRule.waitForIdle()

        verify(exactly = 1) { chatStreamingManager.stopStream(CONVERSATION_ID) }
    }

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
            // EnhancedComposer only reaches Koin for ProviderRepository; hand it the same mock.
            KoinApplication(application = { modules(module { single<ProviderRepository> { providerRepository } }) }) {
                OriveoTheme(darkTheme = false) {
                    ChatComposerHost(
                        viewModel = viewModel,
                        activeProvider = provider,
                        conversationId = CONVERSATION_ID,
                        conversationSkillId = null,
                        sendingBlockedByLoadState = false,
                        transparentChrome = false,
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

    private companion object {
        const val CONVERSATION_ID = "conversation-1"
    }
}
