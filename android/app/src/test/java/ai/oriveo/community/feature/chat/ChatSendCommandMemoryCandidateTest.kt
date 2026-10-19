package ai.oriveo.community.feature.chat

import androidx.room.Room
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.MemoryProposeMode
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.memory.MemoryProposeSendHook
import ai.oriveo.community.core.memory.ProposeMemoryRuntime
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.AttachmentSendPreflight
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Memory candidates of the send command: the candidate is still written after leaving the page, it is stored under the account at send time,
 * and relay web search takes part in the propose mode decision by the switch at the moment of sending (the user turning it off on the advanced page = web search off, matching iOS).
 */
@RunWith(RobolectricTestRunner::class)
@OptIn(ExperimentalCoroutinesApi::class)
class ChatSendCommandMemoryCandidateTest {
    private val dispatcher = StandardTestDispatcher()
    // The send entry generates candidates in real time, so the repository clock starts from now to keep them from being swept as expired.
    private var clock = System.currentTimeMillis()

    private val db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
        .allowMainThreadQueries()
        .setQueryExecutor { it.run() }
        .setTransactionExecutor { it.run() }
        .build()
    private val candidates: MemoryCandidateRepository

    init {
        val preferences = AppPreferencesRepository(preferenceDao = db.preferenceDao())
        val items = MemoryItemRepository(dao = db.memoryItemDao(), preferenceDao = db.preferenceDao(), preferences = preferences)
        candidates = MemoryCandidateRepository(
            dao = db.memoryCandidateDao(),
            items = items,
            now = { clock },
            io = Dispatchers.Unconfined,
            preferences = preferences,
        )
    }

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        ProposeMemoryRuntime.clearForTest()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        ProposeMemoryRuntime.clearForTest()
        db.close()
    }

    /** Sentences are taken by id from the cases in shared/context-contracts/memory-intent.v1.json instead of being hard-coded. */
    private val cases: Map<String, JsonObject> by lazy {
        ContextContractFixture.cases(ContextContractFixture.load("memory-intent.v1.json"), "cases").associateBy { it.id() }
    }

    private fun text(id: String): String = cases.getValue(id)["text"]!!.jsonPrimitive.content

    @Test
    fun candidate_written_after_leaving_page() = runTest {
        // The page viewModelScope is separate from the memoryScope used by candidates: leave the page right after the user message is stored (cancelling viewModelScope).
        val pageScope = CoroutineScope(coroutineContext + Job(coroutineContext[Job]))
        val send = sendEntry(
            viewModelScope = pageScope,
            proposeMode = MemoryProposeMode.FALLBACK,
            afterUserMessage = { pageScope.coroutineContext[Job]!!.cancel() },
        )

        send(text("zh_explicit_01_golden"))

        assertFalse("page scope was left", pageScope.coroutineContext[Job]!!.isActive)
        val candidate = candidates.pending(ACCOUNT).single()
        assertEquals("message-1", candidate.source.messageIds.single())
    }

    @Test
    fun candidate_uses_account_at_send_time() = runTest {
        var account = ACCOUNT
        val send = sendEntry(
            accountId = { account },
            proposeMode = MemoryProposeMode.FALLBACK,
            // Switch account after the user message is stored and before the candidate is generated: the candidate still lands in the partition at send time.
            afterUserMessage = { account = OTHER_ACCOUNT },
        )

        send(text("zh_explicit_01_golden"))

        assertEquals(OTHER_ACCOUNT, account)
        assertEquals("message-1", candidates.pending(ACCOUNT).single().source.messageIds.single())
        assertTrue("switched-to account gets nothing", candidates.pending(OTHER_ACCOUNT).isEmpty())
    }

    @Test
    fun relay_web_user_disabled_counts_as_web_off() = runTest {
        // Gemini generateContent relay with chat web search on: without a user override it actually sends web search -> fallback (no propose hook attached).
        val webOn = sendEntry(
            relayTransport = RelayTransport.GeminiGenerateContent,
            webSearchEnabled = true,
        )
        webOn.send(text("zh_explicit_01_golden"))
        assertNull("web actually on: fallback", webOn.hooks.single())

        // The user overrides web search to off on the advanced page: nothing is sent with web search, Gemini no longer conflicts -> tool mode (hook attached).
        val userOff = sendEntry(
            relayTransport = RelayTransport.GeminiGenerateContent,
            webSearchEnabled = true,
            webOverride = RelayCapabilityOverrides(web = false),
        )
        userOff.send(text("zh_explicit_01_golden"))
        assertNotNull("user override off counts as web off: tool mode", userOff.hooks.single())
    }

    private class Entry(val send: suspend (String) -> Unit, val hooks: List<MemoryProposeSendHook?>) {
        suspend operator fun invoke(sentence: String) = send(sentence)
    }

    @Suppress("LongParameterList")
    private fun TestScope.sendEntry(
        viewModelScope: CoroutineScope = this,
        accountId: () -> String = { ACCOUNT },
        proposeMode: MemoryProposeMode? = null,
        afterUserMessage: () -> Unit = {},
        relayTransport: RelayTransport = RelayTransport.OpenAIChatCompletions,
        webSearchEnabled: Boolean = false,
        webOverride: RelayCapabilityOverrides? = null,
    ): Entry {
        val model = AIModel(
            id = MODEL_ID,
            name = "Model",
            isDefault = true,
            capabilities = listOf(ModelCapability.Text),
            toolCall = true,
            relayCapabilityOverrides = webOverride,
        )
        val provider = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = relayTransport),
            models = listOf(model),
            catalogModels = listOf(model),
        )
        val conv = Conversation(
            id = "conversation-1",
            title = "t",
            providerID = provider.id,
            providerKind = ProviderKind.Relay,
            modelID = MODEL_ID,
            messages = emptyList(),
            updatedAt = 1L,
        ).copy(useMemory = true)
        val providerRepository = mockk<ProviderRepository>()
        val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        coEvery { providerRepository.getById(provider.id) } returns provider
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any<String>()) } returns IDENTITY
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { conversationRepository.getWithMessages(conv.id) } returns conv
        var sends = 0
        val hooks = mutableListOf<MemoryProposeSendHook?>()
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = viewModelScope,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { conv },
            currentConversationId = { conv.id },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            resolveAttachmentSendOptions = { _, _ ->
                AttachmentSendPreflight.SendOptions(
                    reasoningMode = ReasoningMode.Automatic,
                    webSearchEnabled = webSearchEnabled,
                    toolLoopPossible = false,
                )
            },
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> },
            launchUserSend = ChatUserSendLauncher { _, _, _, sent, _, _, _, _, onUserMessageCreated, hook ->
                sends++
                hooks += hook
                onUserMessageCreated("message-$sends", sent)
                afterUserMessage()
            },
            memoryCandidates = candidates,
            memoryAccountId = accountId,
            memoryScope = this,
            memoryProposeMode = proposeMode?.let { mode -> { _, _, _ -> mode } },
        )
        return Entry(
            send = { sentence ->
                clock += 1_000
                coordinator.sendMessage(sentence, null, provider.id, MODEL_ID)
                advanceUntilIdle()
            },
            hooks = hooks,
        )
    }

    private companion object {
        const val ACCOUNT = "account-1"
        const val OTHER_ACCOUNT = "account-2"
        const val MODEL_ID = "m-1"
        val IDENTITY = CapabilityEvidenceIdentity(
            partitionId = "u1", connectionInstanceId = "relay-1", connectionGeneration = "g1", credentialEpoch = "c1",
            providerKind = ProviderKind.Relay.rawValue, metadataRevision = "m1", generationRevision = "g1",
            authMode = ProviderAuthMode.ApiKey.rawValue,
        )
    }
}
