package ai.oriveo.community.feature.chat.composer

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
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
import ai.oriveo.community.core.voice.DictationController
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
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
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.koin.compose.KoinApplication
import org.koin.dsl.module

/**
 * The ≋ main key is hidden while chat dictation is recording / transcribing (matches the iOS
 * voiceDictationRecording / voiceDictationTranscribing states): while recording only the recording
 * bar and its own ↑ remain, while transcribing only the recording bar remains; the main key is
 * unchanged when idle and on the interrupted card.
 * A real [ChatViewModel], a real [ChatComposerHost] and a real `EnhancedComposer`; the dictation
 * controller is injected through Koin with controllable state.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatComposerDictationMainKeyUiTest {

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

    private val dictationState = MutableStateFlow<DictationState>(DictationState.Idle)
    private val dictationController = mockk<DictationController>(relaxed = true) {
        every { state } returns dictationState
        every { engineInfo } returns MutableStateFlow<DictationEngineInfo?>(null)
        every { pendingDurationSec } returns MutableStateFlow<Double?>(null)
        every { levelMeter } returns MutableStateFlow(listOf(0.2f, 0.6f, 1f))
        every { boundOwner } returns MutableStateFlow<Any?>(null)
    }

    /** The conversation's active streaming message id; flipping it is what ChatRepository does. */
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
        title = "Dictation main key test",
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
        // KoinApplication starts a process-wide instance; leaving it running fails the next test with
        // KoinApplicationAlreadyStartedException.
        org.koin.core.context.stopKoin()
        Dispatchers.resetMain()
    }

    @Test
    fun `idle dictation keeps the voice main key`() {
        launchHost()
        composeRule.onNodeWithContentDescription(voice()).assertExists()
    }

    @Test
    fun `recording hides the voice main key and keeps the bar send`() {
        launchHost()
        composeRule.runOnIdle { dictationState.value = DictationState.Recording(CONVERSATION_ID, 0L) }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription(voice()).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(
            context().getString(ai.oriveo.community.R.string.voice_dictation_transcribe_and_send),
        ).assertExists()
    }

    @Test
    fun `transcribing hides the voice main key`() {
        launchHost()
        composeRule.runOnIdle {
            dictationState.value = DictationState.Transcribing(CONVERSATION_ID, DictationSubmit.Insert)
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription(voice()).assertDoesNotExist()
    }

    @Test
    fun `main key comes back after recording ends and stays on the interrupted card`() {
        launchHost()
        composeRule.runOnIdle { dictationState.value = DictationState.Recording(CONVERSATION_ID, 0L) }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(voice()).assertDoesNotExist()

        composeRule.runOnIdle { dictationState.value = DictationState.Interrupted(CONVERSATION_ID) }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(voice()).assertExists()
    }

    private fun voice(): String = context().getString(ai.oriveo.community.R.string.voice_conversation_start_a11y)

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
            // EnhancedComposer reaches Koin for ProviderRepository; the dictation host reaches Koin for DictationController.
            val testModule = module {
                single<ProviderRepository> { providerRepository }
                single<DictationController> { dictationController }
            }
            KoinApplication(application = { modules(testModule) }) {
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

    private lateinit var activity: ComponentActivity

    private companion object {
        const val CONVERSATION_ID = "conversation-1"
    }
}
