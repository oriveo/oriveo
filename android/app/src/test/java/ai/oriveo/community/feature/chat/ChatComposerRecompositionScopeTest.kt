package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.compose.runtime.snapshots.Snapshot
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
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import java.io.File
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pins **the composer's recomposition scope**: typing may only invalidate the composer itself.
 *
 * None of this chain is visible in the code, so it can only be held by invariants. A single read of
 * `viewModel.inputText` (snapshot state) in `ChatScreenContent` invalidates the root composable on
 * every keystroke; once `ChatMessagesList` recomposes with it, foundation's
 * `rememberLazyListItemProviderLambda` swaps in a fresh `LazyListIntervalContent` and **every
 * visible cell recomposes along with its markdown subtree**.
 *
 * The same amplification path has three other entrances, and missing any one of them makes "the
 * list does not recompose" a false pass: collecting the `debounce(250)` related notes at the root,
 * the 350ms draft debounce punching through `observeMetadata`, and lambdas that capture the
 * ViewModel without being remembered.
 *
 * The draft lifecycle is the highest-risk part of this change, so the behavioural cases come before
 * the structural ones.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatComposerRecompositionScopeTest {

    private val screenContentSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
    }
    private val composerHostSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/composer/ChatComposerHost.kt").readText()
    }
    private val viewModelSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/ChatViewModel.kt").readText()
    }
    private val screenEffectsSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenEffects.kt").readText()
    }
    private val draftCoordinatorSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/ChatConversationActions.kt").readText()
    }
    private val enhancedComposerSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt").readText()
    }

    // ── structure: per-keystroke state has to live inside the composer ──

    @Test
    fun `chat screen root reads neither the composer text nor the debounced related notes`() {
        assertFalse(
            "reading viewModel.inputText in the root scope recomposes the whole page on every keystroke (and the entire ChatMessagesList with it)",
            screenContentSource.contains("viewModel.inputText"),
        )
        assertFalse(
            "relatedNotes is a debounce(250) derivative of the input; collecting it at the root recomposes the whole page every 250ms",
            screenContentSource.contains("noteCoordinator.relatedNotes.collectAsStateWithLifecycle()"),
        )
        assertFalse(
            "attachedNotes is only consumed by the composer; collecting it at the root widens the recomposition surface for nothing",
            screenContentSource.contains("noteCoordinator.attachedNotes.collectAsStateWithLifecycle()"),
        )
    }

    @Test
    fun `composer host owns the text locally and only external pushes can overwrite it`() {
        assertTrue(
            "the per-keystroke text has to be the host's local state",
            composerHostSource.contains("val composerText = remember { mutableStateOf(restore.text) }"),
        )
        assertTrue(
            "overwriting the field must key off the one-shot token; keying on restore.text breaks 'clear, then type the same thing again'",
            composerHostSource.contains("LaunchedEffect(restore.token) { composerText.value = restore.text }"),
        )
        assertTrue(
            "related notes have to be collected inside the host",
            composerHostSource.contains("relatedNotes.collectAsStateWithLifecycle()"),
        )
        assertTrue(
            "the typing callback writes the local state and also sends the outbound truth back to the view model (sending, drafts and note recall all read it)",
            composerHostSource.contains("viewModel.onInputTextChanged(it)"),
        )
    }

    /**
     * The per-keystroke recomposition surface must collapse to the text field **itself**.
     *
     * "The root does not recompose" is only the pass mark: re-running `EnhancedComposer`'s
     * thousand-plus line body (capability resolution, attachment counting, a pile of
     * `stringResource` lookups) on every character is just as real a cost. So the text travels as a
     * lazy read: the host does not read it, `EnhancedComposer` has no String parameter, and only
     * `ComposerTextField` calls the provider inside its own scope, which is where the subscription
     * is created.
     */
    @Test
    fun `only the text field itself subscribes to the composer text`() {
        assertTrue(
            "the host must not read the text in its body: doing so recomposes this composable on every keystroke, " +
                "which hands EnhancedComposer fresh viewModel:: method references and makes it non skippable too",
            composerHostSource.contains("val inputTextProvider = remember { { composerText.value } }"),
        )
        assertTrue(
            "the body only needs 'is there any text'; derivedStateOf compresses per-keystroke changes into a boolean flip",
            composerHostSource.contains("derivedStateOf { composerText.value.isNotBlank() }"),
        )
        // The text may appear in only three shapes: a write, the lazy-read provider, and the
        // boolean derivation. Any other line is the host body reading the text directly, which
        // voids the protection on the spot.
        val unsafeReads = composerHostSource.lineSequence()
            .filterNot { it.trim().startsWith("//") }
            .filter { it.contains("composerText.value") }
            .filterNot { it.contains("composerText.value =") }
            .filterNot { it.contains("remember { { composerText.value } }") }
            .filterNot { it.contains("derivedStateOf { composerText.value") }
            .map { it.trim() }
            .toList()
        assertTrue("these lines read the text directly in the host body: $unsafeReads", unsafeReads.isEmpty())
        assertFalse(
            "the moment EnhancedComposer takes a String parameter it becomes non skippable per keystroke, voiding the lazy read entirely",
            Regex("""\n\s{4}inputText:\s*String,""").containsMatchIn(enhancedComposerSource),
        )
        assertTrue(
            "the text field has to be its own composable, otherwise the subscription point moves back into EnhancedComposer's scope",
            enhancedComposerSource.contains("private fun ComposerTextField("),
        )
        val textFieldAt = enhancedComposerSource.indexOf("private fun ComposerTextField(")
        assertTrue(
            "the provider may only be invoked inside ComposerTextField's own scope",
            enhancedComposerSource.indexOf("val text = textProvider()") > textFieldAt,
        )
        assertEquals(
            "there must be exactly one textProvider() call in the whole file",
            1,
            Regex("""textProvider\(\)""").findAll(enhancedComposerSource).count(),
        )
    }

    @Test
    fun `input text is not compose snapshot state`() {
        assertFalse(
            "once inputText is a mutableStateOf, every composable that reads it gets dragged into recomposition by typing",
            Regex("""var\s+inputText:\s*String\s+by\s+mutableStateOf""").containsMatchIn(viewModelSource),
        )
        assertFalse(
            "same inside the coordinator: the text itself must not go back into the snapshot system",
            Regex("""var\s+text:\s*String\s+by\s+mutableStateOf""").containsMatchIn(draftCoordinatorSource),
        )
        assertTrue(
            "note recall subscribes to a StateFlow instead: snapshotFlow cannot observe a non-snapshot field and would silently stop updating",
            draftCoordinatorSource.contains("val textFlow = MutableStateFlow(\"\")"),
        )
        assertTrue(
            "typing must not bump the restore token",
            draftCoordinatorSource.contains("fun onInputTextChanged(text: String, conversationId: String?)"),
        )
    }

    @Test
    fun `message list callbacks that capture the view model are remembered`() {
        val callAt = screenContentSource.indexOf("                    ChatMessagesList(")
        assertTrue("the ChatMessagesList call is gone", callAt > 0)
        val block = screenContentSource.substring(callAt, screenContentSource.indexOf("\n                }", callAt))

        assertFalse(
            "the ViewModel is unstable, so the compiler does not memoize method references on it: one root recomposition swaps in a new intervalContent and recomposes the whole list",
            block.contains("viewModel::"),
        )
        assertFalse(
            "same again: a bare lambda capturing viewModel has to be remembered before it is passed in",
            block.contains("-> viewModel."),
        )
        assertTrue(
            "the callbacks must be the pre-remembered instances",
            block.contains("onCopy = onCopyMessage,") && block.contains("onRegenerate = onRegenerateMessage,"),
        )
        assertTrue(
            "remember has to key on the captured unstable references, or the callbacks keep pointing at the old ViewModel/Context",
            screenContentSource.contains("val onCopyMessage = remember(viewModel, context)"),
        )
    }

    @Test
    fun `draft is flushed on ON_STOP not only when the screen is disposed`() {
        assertTrue(
            "pressing Home does not dispose the composition, so onDispose cannot catch the 350ms draft window",
            screenEffectsSource.contains("Lifecycle.Event.ON_STOP"),
        )
        assertTrue(
            "the ON_STOP observer has to be registered on the chat screen's own lifecycleOwner and removed when it leaves",
            screenEffectsSource.contains("lifecycleOwner.lifecycle.removeObserver(observer)"),
        )
        assertTrue(
            "the effect has to actually be mounted by the chat screen",
            screenContentSource.contains("ChatDraftLifecycleFlushEffect(flushDraft = flushDraft)"),
        )
        assertTrue(
            "the onDispose one stays (they complement each other, one does not replace the other)",
            screenContentSource.contains("ChatScreenLeavingEffect(handleScreenLeaving)"),
        )
    }

    // ── behaviour: typing writes no snapshot state ──

    @Test
    fun `typing writes no compose snapshot state at all`() = runTest {
        stubExistingConversation("conversation-1")
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()
        // Drain the global snapshot changes queued during construction first, so they are not
        // attributed to typing.
        Snapshot.sendApplyNotifications()

        val changed = mutableListOf<Any>()
        val handle = Snapshot.registerApplyObserver { states, _ -> changed.addAll(states) }
        try {
            listOf("h", "he", "hel", "hell", "hello").forEach(viewModel::onInputTextChanged)
            Snapshot.sendApplyNotifications()
        } finally {
            handle.dispose()
        }

        assertTrue("typing wrote snapshot state, so the whole page recomposes with it: $changed", changed.isEmpty())
        assertEquals("hello", viewModel.inputText)
    }

    @Test
    fun `typing never bumps the composer restore token`() = runTest {
        stubExistingConversation("conversation-1")
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()

        val tokenBeforeTyping = viewModel.composerTextRestore.token
        listOf("h", "he", "hel").forEach(viewModel::onInputTextChanged)
        advanceUntilIdle()

        assertEquals(
            "the moment the token moves the composer pushes the text straight back, which reconnects the whole-page recomposition",
            tokenBeforeTyping,
            viewModel.composerTextRestore.token,
        )
        assertEquals("hel", viewModel.inputText)
    }

    // ── behaviour: draft lifecycle (the easiest part of this change to regress) ──

    @Test
    fun `entering a conversation hydrates its draft through a restore token`() = runTest {
        stubExistingConversation(buildConversation("conversation-1").copy(draftText = "unsent question"))
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()

        assertEquals("unsent question", viewModel.inputText)
        assertEquals("unsent question", viewModel.composerTextRestore.text)
        assertTrue("draft hydration has to bump the token, or the composer still shows empty", viewModel.composerTextRestore.token > 0)
    }

    @Test
    fun `starting a new chat clears the composer through a restore token`() = runTest {
        stubExistingConversation(buildConversation("conversation-1").copy(draftText = "unsent question"))
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()
        val tokenAfterHydrate = viewModel.composerTextRestore.token

        viewModel.startNewChat()
        advanceUntilIdle()

        assertEquals("", viewModel.inputText)
        assertEquals("", viewModel.composerTextRestore.text)
        assertNotEquals(tokenAfterHydrate, viewModel.composerTextRestore.token)
    }

    @Test
    fun `leaving the screen flushes exactly the text typed after the last debounce`() = runTest {
        stubExistingConversation("conversation-1")
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()

        viewModel.onInputTextChanged("half typed")
        // The scheduler is deliberately not advanced: this is the user typing the last character and
        // leaving immediately, before the 350ms debounce has run.
        viewModel.handleChatScreenLeaving()
        advanceUntilIdle()

        coVerify(exactly = 1) { conversationRepository.updateDraft("conversation-1", "half typed") }
    }

    @Test
    fun `sending clears the composer and the pending debounce never writes the sent text back`() = runTest {
        stubExistingConversation("conversation-1")
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()

        viewModel.onInputTextChanged("send me")
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("", viewModel.inputText)
        assertEquals("", viewModel.composerTextRestore.text)
        coVerify(exactly = 1) { conversationRepository.updateDraft("conversation-1", "") }
        // Ghost draft regression lock: the debounce queued by the last keystroke has to be cancelled
        // first, otherwise it runs after the clear, writes the already-sent question back into the
        // draft and leaves it there for good.
        coVerify(exactly = 0) { conversationRepository.updateDraft("conversation-1", "send me") }
    }

    @Test
    fun `a rejected send leaves both the composer text and the restore token untouched`() = runTest {
        stubExistingConversation("conversation-1")
        // Provider resolution fails: sendMessage returns early, before onComposerConsumed.
        coEvery { providerRepository.getById("provider-1") } returns null
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()

        viewModel.onInputTextChanged("first send fails")
        advanceUntilIdle()
        val tokenBeforeSend = viewModel.composerTextRestore.token
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("first send fails", viewModel.inputText)
        assertEquals(
            "a failed send must not bump the token -- doing so resets the field to whatever was pushed last",
            tokenBeforeSend,
            viewModel.composerTextRestore.token,
        )
    }

    @Test
    fun `an unrelated conversation re-emission keeps the composer text`() = runTest {
        val conversation = buildConversation("conversation-1")
        val metadata = MutableStateFlow<Conversation?>(conversation)
        every { conversationRepository.observeMetadata("conversation-1") } returns metadata
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversation
        windowStore.put("conversation-1", conversation.messages)

        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()
        viewModel.onInputTextChanged("typed before the rename")
        advanceUntilIdle()
        val tokenBeforeReemit = viewModel.composerTextRestore.token

        // The conversation re-emits (its title or other metadata changed) but the id is the same.
        metadata.value = conversation.copy(title = "renamed")
        advanceUntilIdle()

        assertEquals("typed before the rename", viewModel.inputText)
        assertEquals(tokenBeforeReemit, viewModel.composerTextRestore.token)
    }

    @Test
    fun `restoring text for inline edit pushes it to the composer and schedules the draft`() = runTest {
        stubExistingConversation("conversation-1")
        val viewModel = createViewModel("conversation-1")
        advanceUntilIdle()
        val tokenBefore = viewModel.composerTextRestore.token

        viewModel.restoreInputText("restored question")
        advanceUntilIdle()

        assertEquals("restored question", viewModel.inputText)
        assertEquals("restored question", viewModel.composerTextRestore.text)
        assertNotEquals(tokenBefore, viewModel.composerTextRestore.token)
        coVerify(exactly = 1) { conversationRepository.updateDraft("conversation-1", "restored question") }
    }

    // ── fixtures ──

    private val dispatcher = StandardTestDispatcher()
    private val applicationScope = kotlinx.coroutines.CoroutineScope(dispatcher + kotlinx.coroutines.SupervisorJob())
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val chatRepository = mockk<ChatRepository>()
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val windowStore = MessageWindowFakeStore()

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
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow(null)
        ai.oriveo.community.testing.installChatStreamingManagerForwardingStub(chatStreamingManager, chatRepository)
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } just runs
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        coEvery { appPreferencesRepository.markMemoryUsedInConversation(any()) } returns Unit
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { appPreferencesRepository.markProviderDisclosureAccepted(any()) } returns Unit
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
        coEvery { conversationRepository.getWithMessages(any()) } returns null
        coEvery { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) } returns Unit
        coEvery { conversationRepository.updateDraft(any(), any()) } returns Unit
        coEvery {
            chatRepository.sendMessage(
                conversation = any(),
                text = any(),
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                antiForgetText = any(),
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun stubExistingConversation(id: String) = stubExistingConversation(buildConversation(id))

    private fun stubExistingConversation(conversation: Conversation) {
        val id = conversation.id
        every { conversationRepository.observeMetadata(id) } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages(id) } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow(id, any()) } returns conversation
        windowStore.put(id, conversation.messages)
    }

    private fun createViewModel(conversationId: String?): ChatViewModel = ChatViewModel(
        savedStateHandle = if (conversationId != null) {
            SavedStateHandle(mapOf("conversationId" to conversationId))
        } else {
            SavedStateHandle()
        },
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

    private fun buildConversation(id: String): Conversation = Conversation(
        id = id,
        title = "Composer scope test",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o-mini",
        messages = emptyList(),
    )
}
